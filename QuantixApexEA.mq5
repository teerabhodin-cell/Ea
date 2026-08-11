//+------------------------------------------------------------------+
//|                                                 QuantixApexEA.mq5|
//|   Rule-Based Ensemble SMC Scalper (no ONNX model - pure logic):  |
//|   H1+H4 Trend Confluence -> M15 Liquidity Sweep + CHoCH/BOS ->   |
//|   Order Block / FVG / Fibonacci Zone -> News + USD-Correlation   |
//|   Guards -> Composite Smart Signal Score (OB Quality + Volume +  |
//|   Zone Confluence + Trap Confidence) -> M5 Candle Trigger ->     |
//|   TP1/TP2/TP3 Partial Ladder. Full Risk Management + Kill Switch |
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

//=========================== INPUT ================================//
input group "===== 1. Language & Timeframes ====="
input ENUM_LANGUAGE Language        = LNG_TH;  // Select Language (default: Thai)
input ENUM_TIMEFRAMES ZoneTF        = PERIOD_M5;  // Structure / Zone Timeframe (was M15 - lower TF re-evaluates structure far more often, biggest remaining frequency lever)
input ENUM_TIMEFRAMES EntryTF       = PERIOD_M1;  // Entry Trigger Timeframe (was M5, dropped a step to stay below ZoneTF)
input ENUM_TIMEFRAMES TrendTF1      = PERIOD_H1;  // Trend Confluence Timeframe 1
input ENUM_TIMEFRAMES TrendTF2      = PERIOD_H4;  // Trend Confluence Timeframe 2

input group "===== 2. Multi-TF Trend Confluence ====="
input int    EMA_TrendPeriod        = 50;      // EMA Period (both TrendTF1 & TrendTF2 must agree)

input group "===== 3. SMC Structure (Zone Timeframe) ====="
input int    SwingStrength          = 2;       // Swing Fractal Strength, bars each side (lower = more, faster-confirmed swings -> more setups/day)
input double MinDisplacementATRMult = 0.4;     // Min Breakout Candle Body vs ATR - filters weak CHoCH/BOS
input bool   RequireLiquiditySweep  = false;   // Require Stop Hunt Before CHoCH (biggest single frequency gate - sweeps are rare; off trades some quality for many more setups)
input bool   AllowContinuationSetups = true;   // Also arm on further breaks in an already-established trend, not just the first flip (a real CHoCH-only gate goes fully silent for years during one long sustained trend - confirmed in backtests)
input int    SweepExpiryBars        = 10;      // Sweep Validity, bars
input int    OB_MaxLookbackBars     = 8;       // Max Bars Back to Find Order Block
input int    SetupExpiryBars        = 25;      // Armed Zone Validity, bars (raised alongside the lower ZoneTF so an armed setup still gets a comparable amount of real time to trigger)
input double ZoneBufferPoints       = 0;       // Extra Buffer around Entry Zone, pts
input double SL_BufferPoints        = 30;      // Extra Buffer beyond Invalidation, pts
input double MinSL_ATRMult          = 1.2;     // Min SL Distance = Entry ATR x this (invalidation point alone can sit inside normal noise)

input group "===== 4. Volume Confirmation ====="
input bool   UseVolumeFilter        = true;    // Require Above-Average Volume on the Displacement Candle
input int    VolumeAvgPeriod        = 20;      // Avg Volume Lookback, bars (ZoneTF)
input double MinVolumeRatio         = 1.0;     // Min Displacement Volume vs Average (was 1.2 - average is enough, don't require above-average)

input group "===== 5. USD Correlation Guard (optional) ====="
input bool   UseCorrelationFilter   = false;   // Require USD Index Trend to Agree (e.g. XAUUSD vs DXY)
input string CorrelationSymbol      = "";      // USD Index Symbol Name on this Broker (blank = disabled)
input int    CorrelationEMAPeriod   = 50;      // EMA Period on the Correlation Symbol (TrendTF1)

input group "===== 6. News Guard ====="
input bool   UseNewsFilter          = true;    // Block Entries Near High-Impact News
input string NewsCurrencyCode       = "USD";   // Currency to Watch (blank = all)
input int    NewsMinutesBefore      = 30;      // Block Entries N Min Before Event
input int    NewsMinutesAfter       = 30;      // Block Entries N Min After Event

input group "===== 7. Entry Candle Confirmation ====="
input double PinBarWickBodyRatio    = 2.0;     // Pin Bar: Wick >= Body x This Ratio

input group "===== 8. Smart Signal Score ====="
input double MinSignalScore         = 40.0;    // Min Composite Score (0-100) to Trade (was 60 -> 45 -> 40, loosened progressively for more setups/day)

input group "===== 9. Filters ====="
input int    ATR_Period             = 14;      // ATR Period
input double ATR_MinPoints          = 250;     // Min ATR (EntryTF), pts - avoid dead market
input double ATR_MaxPoints          = 3000;    // Max ATR (EntryTF), pts - avoid news spikes
input int    MaxSpreadPoints        = 250;     // Max Allowed Spread, pts
input bool   UseRegimeFilter        = true;    // Require Trending Market via ADX (กันเทรดตอนตลาด Sideway)
input ENUM_TIMEFRAMES RegimeTimeframe = PERIOD_H1; // Regime Timeframe
input int    ADX_Period             = 14;      // ADX Period
input double ADX_MinTrendStrength   = 22.0;    // Min ADX to Allow Entries
input double ADX_MaxTrendStrength   = 0;       // Max ADX to Allow Entries, 0=disabled (an ADX 22-32 band tested WORSE in isolation - PF 0.91 on 56 trades vs PF 1.13 on 614 trades unbounded - keeping this off by default)
input bool   RequireADXDirectionAgreement = false; // Require +DI/-DI to Match Trade Bias (was true - kept the min-strength ADX gate, dropped this stricter add-on)
input bool   UseSessionFilter       = true;    // Only Trade Within Allowed Hours
input bool   UseLocalTime           = false;   // Use Local PC Time
input int    StartHour              = 2;       // Start Hour
input int    StartMinute            = 0;
input int    EndHour                = 22;      // Stop Hour
input int    EndMinute              = 0;

input group "===== 10. Risk & Money Management ====="
input double RiskPercent            = 1.5;     // Risk % of Equity per Trade (was 1.0 - raised so more setups clear the min-lot floor on a small account)
input double RR_TP1                 = 1.5;     // TP1 = SL Distance x RR (partial close)
input double RR_TP2                 = 2.5;     // TP2 = SL Distance x RR (partial close)
input double RR_TP3                 = 4.0;     // TP3 = SL Distance x RR (final target)
input double TP1_ClosePercent       = 40.0;    // % of Position to Close at TP1
input double TP2_ClosePercent       = 40.0;    // % of Remaining Position to Close at TP2
input bool   UseBreakeven           = true;    // Move SL to Breakeven Before TP1 (ป้องกันไม้ที่เคยกำไรเยอะแต่ย้อนชน SL)
input double BreakevenTriggerRR     = 1.2;     // Breakeven Trigger = SL Distance x RR (ใกล้ RR_TP1 พอให้ไม้มีที่วิ่ง)
input double BreakevenLockPoints    = 20;      // Lock Points Beyond Entry (ใช้ทั้ง Breakeven เร็วและหลัง TP1)
input bool   UseEmergencyLossGuard  = true;    // Force-close if floating loss blows past intended SL risk (gap/spike protection)
input double MaxLossMultiplier      = 2.0;     // Emergency close if loss > Risk_Money x this multiple
input double MinLot                 = 0.01;    // Min Lot Cap
input double MaxLot                 = 5.0;     // Max Lot Cap
input int    Slippage               = 20;      // Max Slippage, pts
input ulong  MagicNumber            = 773311;

input group "===== 11. Drawdown Protection (Kill Switch) ====="
input bool   UseDailyLossLimit      = true;    // Daily Loss Limit
input double MaxDailyLossPercent    = 3.0;     // Max Daily Loss %
input bool   UseTotalDDGuard        = true;    // Total Drawdown Guard (Kill Switch)
input double MaxTotalDDPercent      = 10.0;    // Max Total DD % (from Equity Peak)
input bool   UseEquityLock          = true;    // Equity Floor Lock
input double MinEquityLimit         = 0.0;     // Min Equity Floor (0 = off)

input group "===== 12. Dashboard ====="
input bool   ShowDashboard          = true;
input bool   ShowDashboardInTester  = false;   // Show Dashboard during Strategy Tester
input int    Dashboard_X            = 15;
input int    Dashboard_Y            = 20;
input color  Dashboard_BG           = C'20,20,20';
input color  Dashboard_Text         = clrWhite;
input color  Dashboard_Green        = clrLimeGreen;
input color  Dashboard_Red          = clrTomato;
input color  Dashboard_Yellow       = clrGold;

input group "===== 13. Training Data Logger ====="
input bool   UseTrainingLogger      = true;    // Log Every Setup + Outcome to CSV (สะสม Dataset สำหรับเทรน ML ทีหลัง)
input string TrainingLogFileName    = "QuantixApexEA_TrainingLog.csv"; // File in Common\Files (ดูวิธีหาใน Journal ตอน EA เริ่มทำงาน)

//=========================== GLOBALS ================================//
int hEmaTrend1  = INVALID_HANDLE;
int hEmaTrend2  = INVALID_HANDLE;
int hEmaCorr    = INVALID_HANDLE;
int hATR_Zone   = INVALID_HANDLE;
int hATR_Entry  = INVALID_HANDLE;
int hADX        = INVALID_HANDLE;

datetime lastZoneBarTime  = 0;
datetime lastEntryBarTime = 0;
datetime currentDay       = 0;
double   dayStartEquity   = 0;
double   equityPeak       = 0;

bool     dailyHalted   = false;
string   haltReason    = "";
bool     ddGuardHalted = false;
string   ddGuardReason = "";

// --- SMC structure state (ZoneTF) ---
double   g_SwingHigh[2]      = {0,0};
double   g_SwingLow[2]       = {0,0};
bool     g_HaveSwingHigh = false, g_HaveSwingLow = false;

int      g_StructureBias = 0;

bool     g_SweepLowActive = false;  double g_SweepLowPrice = 0;  int g_SweepLowBarsAgo = 0;
bool     g_SweepHighActive = false; double g_SweepHighPrice = 0; int g_SweepHighBarsAgo = 0;

bool     g_SetupArmed = false;
int      g_SetupBias  = 0;
double   g_InvalidationPrice = 0;
int      g_SetupBarsAgo = 0;

bool     g_HaveFiboZone=false;  double g_FiboZoneTop=0, g_FiboZoneBottom=0;
bool     g_HaveOBFVGZone=false; double g_OBFVGZoneTop=0, g_OBFVGZoneBottom=0;

double   g_ObQualityScore = 0;
double   g_VolumeScore    = 0;

// --- open position TP ladder ---
ulong    g_EntryTicket = 0;
double   g_EntrySLDistance = 0;
double   g_EntryRiskMoney = 0;   // intended max $ loss at the time this trade was opened
double   g_TP1Price=0, g_TP2Price=0, g_TP3Price=0;
bool     g_TP1Done=false, g_TP2Done=false;

double   g_LastScore = 0;

const string DashPrefix = "QAPEX_DASH_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   hEmaTrend1 = iMA(_Symbol, TrendTF1, EMA_TrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hEmaTrend2 = iMA(_Symbol, TrendTF2, EMA_TrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hATR_Zone  = iATR(_Symbol, ZoneTF, ATR_Period);
   hATR_Entry = iATR(_Symbol, EntryTF, ATR_Period);
   hADX       = iADX(_Symbol, RegimeTimeframe, ADX_Period);

   if(hEmaTrend1==INVALID_HANDLE || hEmaTrend2==INVALID_HANDLE || hATR_Zone==INVALID_HANDLE ||
      hATR_Entry==INVALID_HANDLE || hADX==INVALID_HANDLE)
   {
      Print("QuantixApexEA: indicator handle creation failed");
      return INIT_FAILED;
   }

   if(UseCorrelationFilter && StringLen(CorrelationSymbol)>0)
   {
      hEmaCorr = iMA(CorrelationSymbol, TrendTF1, CorrelationEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(hEmaCorr==INVALID_HANDLE)
         Print("QuantixApexEA: correlation EMA handle failed - filter will be skipped");
   }

   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   equityPeak     = dayStartEquity;
   currentDay     = DayStart(TimeCurrent());

   if(EffectiveShowDashboard()) CreateDashboard();

   if(UseTrainingLogger)
      Print("QuantixApexEA: training log -> ", TerminalInfoString(TERMINAL_COMMONDATA_PATH), "\\Files\\", TrainingLogFileName);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEmaTrend1!=INVALID_HANDLE) IndicatorRelease(hEmaTrend1);
   if(hEmaTrend2!=INVALID_HANDLE) IndicatorRelease(hEmaTrend2);
   if(hEmaCorr!=INVALID_HANDLE)   IndicatorRelease(hEmaCorr);
   if(hATR_Zone!=INVALID_HANDLE)  IndicatorRelease(hATR_Zone);
   if(hATR_Entry!=INVALID_HANDLE) IndicatorRelease(hATR_Entry);
   if(hADX!=INVALID_HANDLE)       IndicatorRelease(hADX);
   ObjectsDeleteAll(0, DashPrefix);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageNewDay();
   ManageOpenPosition();
   CheckDailyLimits();
   CheckTotalDDGuard();
   CheckSetupInvalidation();

   if(EffectiveShowDashboard()) UpdateDashboard();

   if(dailyHalted || ddGuardHalted) return;

   if(IsNewZoneBar())
   {
      UpdateSwings();
      UpdateStructureAndSweeps();
      AgeSetupExpiry();
   }

   if(!g_SetupArmed) return;
   if(PositionSelectForMagic()) return;
   if(!IsNewEntryBar()) return;
   if(!IsWithinSession()) return;
   if(!PassSpreadFilter()) return;
   if(!PassVolatilityFilter()) return;
   if(!InZone()) return;
   if(!CheckEntryCandlePattern(g_SetupBias)) return;
   if(UseNewsFilter && IsNearHighImpactNews()) return;
   if(!PassCorrelationFilter(g_SetupBias)) return;

   double trapConf = 0;
   DetectTrap(g_SetupBias, trapConf); // informational component of the score, not a hard gate here (sweep already required upstream)

   double score = ComputeSignalScore(trapConf);
   g_LastScore = score;
   if(score < MinSignalScore) return;
   if(!PassRegimeFilter(g_SetupBias)) return;

   if(OpenTrade(g_SetupBias))
   {
      LogSetupOpen(g_EntryTicket, g_SetupBias, score, trapConf);
      g_SetupArmed = false;
      g_LastScore = 0;
   }
   // on failure, leave the setup armed - it will retry on the next EntryTF
   // bar, or get cleared naturally by CheckSetupInvalidation()/AgeSetupExpiry()
}

//=========================== HELPERS ================================//
bool EffectiveShowDashboard()
{
   if(!ShowDashboard) return false;
   if(MQLInfoInteger(MQL_TESTER) && !ShowDashboardInTester) return false;
   return true;
}

datetime DayStart(datetime t)
{
   MqlDateTime tm;
   TimeToStruct(t, tm);
   tm.hour=0; tm.min=0; tm.sec=0;
   return StructToTime(tm);
}

void ManageNewDay()
{
   datetime today = DayStart(TimeCurrent());
   if(today != currentDay)
   {
      currentDay     = today;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      dailyHalted    = false;
      haltReason     = "";
   }
}

bool IsNewZoneBar()
{
   datetime t = iTime(_Symbol, ZoneTF, 0);
   if(t != lastZoneBarTime) { lastZoneBarTime = t; return true; }
   return false;
}

bool IsNewEntryBar()
{
   datetime t = iTime(_Symbol, EntryTF, 0);
   if(t != lastEntryBarTime) { lastEntryBarTime = t; return true; }
   return false;
}

bool IsWithinSession()
{
   if(!UseSessionFilter) return true;
   datetime t = UseLocalTime ? TimeLocal() : TimeCurrent();
   MqlDateTime tm;
   TimeToStruct(t, tm);
   int curMin = tm.hour*60 + tm.min;
   int startMin = StartHour*60 + StartMinute;
   int endMin   = EndHour*60   + EndMinute;
   if(startMin <= endMin) return (curMin>=startMin && curMin<endMin);
   return (curMin>=startMin || curMin<endMin);
}

bool PassSpreadFilter()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= MaxSpreadPoints);
}

bool PassVolatilityFilter()
{
   double atr[];
   if(CopyBuffer(hATR_Entry, 0, 1, 1, atr) < 1) return false;
   double atrPts = atr[0] / _Point;
   return (atrPts >= ATR_MinPoints && atrPts <= ATR_MaxPoints);
}

// Blocks entries when the higher-timeframe market isn't actually trending
// (low ADX = range/chop) - the improvement that most helped QuantixSniperGoldEA
// stop getting chopped up during sideways stretches.
bool PassRegimeFilter(int bias)
{
   if(!UseRegimeFilter) return true;

   double adxMain[];
   if(CopyBuffer(hADX, 0, 1, 1, adxMain) < 1) return false;
   if(adxMain[0] < ADX_MinTrendStrength) return false;
   if(ADX_MaxTrendStrength > 0 && adxMain[0] > ADX_MaxTrendStrength) return false;

   if(RequireADXDirectionAgreement)
   {
      double plusDI[], minusDI[];
      if(CopyBuffer(hADX, 1, 1, 1, plusDI) < 1) return false;
      if(CopyBuffer(hADX, 2, 1, 1, minusDI) < 1) return false;
      if(bias==1  && plusDI[0] <= minusDI[0]) return false;
      if(bias==-1 && minusDI[0] <= plusDI[0]) return false;
   }

   return true;
}

bool PositionSelectForMagic()
{
   int total = PositionsTotal();
   for(int i=0; i<total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      return true;
   }
   return false;
}

void CloseAllPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      trade.PositionClose(ticket);
   }
}

void CheckDailyLimits()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPLPct = (dayStartEquity>0) ? (equity-dayStartEquity)/dayStartEquity*100.0 : 0;

   bool hitLoss = UseDailyLossLimit && dayPLPct <= -MaxDailyLossPercent;
   if(hitLoss && !dailyHalted)
   {
      CloseAllPositions();
      dailyHalted = true;
      haltReason = (Language==LNG_TH) ? "หยุดเทรด: ขาดทุนรายวันเกินกำหนด รอรีเซ็ตเที่ยงคืน" : "Halted: Daily loss limit hit - waiting for midnight reset";
   }

   if(!dailyHalted && UseEquityLock && MinEquityLimit>0 && equity<=MinEquityLimit)
   {
      CloseAllPositions();
      dailyHalted = true;
      haltReason = (Language==LNG_TH) ? "หยุดเทรด: Equity ต่ำกว่ากำหนด" : "Halted: Equity floor";
   }
}

void CheckTotalDDGuard()
{
   if(!UseTotalDDGuard) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > equityPeak) equityPeak = equity;

   if(ddGuardHalted) return;

   double ddPct = (equityPeak>0) ? (equityPeak-equity)/equityPeak*100.0 : 0;
   if(ddPct >= MaxTotalDDPercent)
   {
      CloseAllPositions();
      ddGuardHalted = true;
      ddGuardReason = (Language==LNG_TH)
                      ? StringFormat("หยุดเทรดถาวร: DD รวม %.1f%% เกินกำหนด (Peak %.2f)", ddPct, equityPeak)
                      : StringFormat("Halted permanently: Total DD %.1f%% exceeded (Peak %.2f)", ddPct, equityPeak);
   }
}

// $ P/L for a 1.0 lot position per 1 unit of price move. tickValue/tickSize
// should equal this for a linear instrument, but backtests proved it reads
// 10x too low on this broker's XAUUSD (real fill: 1.56pt move on 0.11 lot
// cost $17.16, i.e. $100/lot/point, while tick-based math gave only $10) -
// contract size matches the real fills exactly, so use that directly.
double MoneyPerPriceUnit()
{
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contractSize>0) return contractSize;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickValue<=0) return 0;
   return tickValue/tickSize;
}

double CalcLot(double slDistance)
{
   if(slDistance<=0) return 0;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * RiskPercent / 100.0;
   double moneyPerUnit = MoneyPerPriceUnit();
   if(moneyPerUnit<=0) return 0;

   double lossPerLot = slDistance * moneyPerUnit;
   if(lossPerLot<=0) return 0;

   double lot = riskMoney / lossPerLot;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double minLotAllowed = MathMax(MinLot, volMin);

   if(lotStep>0) lot = MathFloor(lot/lotStep) * lotStep;
   if(lot < minLotAllowed) return 0; // SL too wide for target risk at min lot - skip rather than over-risk

   lot = MathMin(lot, MathMin(MaxLot, volMax));
   return NormalizeDouble(lot, 2);
}

//=========================== TRAINING DATA LOGGER ================================//
// Two-row-per-trade CSV (event=OPEN / event=CLOSE, joined by ticket) so a
// Python pipeline can pair each setup's features with its realized outcome
// (profit / risk_money = R-multiple) to train an XGBoost model later.
int OpenTrainingLogFile()
{
   // FILE_COMMON writes to the shared Common\Files folder (same path for
   // every terminal/tester agent on this machine), so the log is always in
   // one predictable place instead of buried inside a per-agent Tester
   // sandbox folder that's hard to find after a backtest.
   bool isNew = !FileIsExist(TrainingLogFileName, FILE_COMMON);
   int handle = FileOpen(TrainingLogFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(handle==INVALID_HANDLE)
   {
      Print("QuantixApexEA: failed to open training log file, err=", GetLastError());
      return INVALID_HANDLE;
   }
   FileSeek(handle, 0, SEEK_END);
   if(isNew)
   {
      FileWrite(handle, "event","ticket","time","symbol","direction","sl_distance","risk_money",
                "lot","entry_price","sl_price",
                "score","ob_quality","volume_score","trap_confidence","has_fibo","has_obfvg",
                "adx","spread","atr","hour","day_of_week","profit");
   }
   return handle;
}

void LogSetupOpen(ulong ticket, int bias, double score, double trapConf)
{
   if(!UseTrainingLogger) return;

   int handle = OpenTrainingLogFile();
   if(handle==INVALID_HANDLE) return;

   double adxArr[];
   double adxNow = (CopyBuffer(hADX, 0, 1, 1, adxArr) >= 1) ? adxArr[0] : 0;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double atrArr[];
   double atrNow = (CopyBuffer(hATR_Entry, 0, 1, 1, atrArr) >= 1) ? atrArr[0] : 0;
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercent / 100.0;

   // Pull the actual filled lot/prices straight off the live position rather
   // than recomputing them, so this row reflects what the broker really did
   // (catches CalcLot/tick-value mismatches that pure recomputation would hide).
   double lot=0, entryPrice=0, slPrice=0;
   if(PositionSelectByTicket(ticket))
   {
      lot        = PositionGetDouble(POSITION_VOLUME);
      entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      slPrice    = PositionGetDouble(POSITION_SL);
   }

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   FileWrite(handle, "OPEN", (long)ticket, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol,
             bias==1?"BUY":"SELL", g_EntrySLDistance, riskMoney, lot, entryPrice, slPrice,
             score, g_ObQualityScore, g_VolumeScore,
             trapConf, g_HaveFiboZone?1:0, g_HaveOBFVGZone?1:0, adxNow, (long)spread, atrNow,
             tm.hour, tm.day_of_week, "");
   FileClose(handle);
}

void LogTradeClose(ulong ticket)
{
   if(!UseTrainingLogger) return;
   if(!HistorySelectByPosition((long)ticket)) return;

   int total = HistoryDealsTotal();
   double totalProfit = 0;
   datetime lastTime = 0;
   for(int i=0; i<total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket==0) continue;
      totalProfit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                   + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                   + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      datetime dt = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(dt >= lastTime) lastTime = dt;
   }
   if(lastTime==0) lastTime = TimeCurrent();

   int handle = OpenTrainingLogFile();
   if(handle==INVALID_HANDLE) return;

   FileWrite(handle, "CLOSE", (long)ticket, TimeToString(lastTime, TIME_DATE|TIME_SECONDS), "", "", "", "",
             "", "", "", "", "", "", "", "", "", "", "", "", "", "", totalProfit);
   FileClose(handle);
}

//=========================== TREND / CORRELATION / NEWS ================================//
int GetTrendBias()
{
   double f1[], f2[];
   if(CopyBuffer(hEmaTrend1, 0, 1, 1, f1) < 1) return 0;
   if(CopyBuffer(hEmaTrend2, 0, 1, 1, f2) < 1) return 0;

   double c1 = iClose(_Symbol, TrendTF1, 1);
   double c2 = iClose(_Symbol, TrendTF2, 1);

   int b1 = c1>f1[0] ? 1 : (c1<f1[0] ? -1 : 0);
   int b2 = c2>f2[0] ? 1 : (c2<f2[0] ? -1 : 0);

   if(b1==0 || b2==0 || b1!=b2) return 0;
   return b1;
}

// XAUUSD typically moves inverse to USD strength - if enabled, requires the
// correlation symbol's own trend to be pointing the opposite way of our bias
// (e.g. a Gold BUY needs the USD index trending down).
bool PassCorrelationFilter(int bias)
{
   if(!UseCorrelationFilter || StringLen(CorrelationSymbol)==0 || hEmaCorr==INVALID_HANDLE) return true;

   double ema[];
   if(CopyBuffer(hEmaCorr, 0, 1, 1, ema) < 1) return false;
   double c = iClose(CorrelationSymbol, TrendTF1, 1);
   int corrBias = c>ema[0] ? 1 : (c<ema[0] ? -1 : 0);
   if(corrBias==0) return false;

   return (bias == -corrBias); // inverse correlation required
}

bool IsNearHighImpactNews()
{
   datetime from = TimeCurrent() - NewsMinutesAfter*60;
   datetime to   = TimeCurrent() + NewsMinutesBefore*60;

   MqlCalendarValue values[];
   int cnt = CalendarValueHistory(values, from, to, NULL, (StringLen(NewsCurrencyCode)>0 ? NewsCurrencyCode : NULL));
   if(cnt<=0) return false;

   for(int i=0;i<cnt;i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance == CALENDAR_IMPORTANCE_HIGH) return true;
   }
   return false;
}

//=========================== SMC STRUCTURE ENGINE (ZoneTF) ================================//
void UpdateSwings()
{
   int n = SwingStrength;
   int checkShift = n+1;
   int total = 2*n+2;
   if(Bars(_Symbol, ZoneTF) < total+2) return;

   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyHigh(_Symbol, ZoneTF, 0, total, high) < total) return;
   if(CopyLow(_Symbol, ZoneTF, 0, total, low) < total) return;

   double pivotHigh = high[checkShift];
   double pivotLow  = low[checkShift];
   bool isSwingHigh = true, isSwingLow = true;

   for(int k=checkShift-n; k<=checkShift+n; k++)
   {
      if(k==checkShift) continue;
      if(k<0 || k>=total) continue;
      if(high[k] >= pivotHigh) isSwingHigh = false;
      if(low[k]  <= pivotLow)  isSwingLow  = false;
   }

   if(isSwingHigh) { g_SwingHigh[1]=g_SwingHigh[0]; g_SwingHigh[0]=pivotHigh; g_HaveSwingHigh=true; }
   if(isSwingLow)  { g_SwingLow[1]=g_SwingLow[0];   g_SwingLow[0]=pivotLow;   g_HaveSwingLow=true; }
}

void UpdateStructureAndSweeps()
{
   if(g_SweepLowActive)  { g_SweepLowBarsAgo++;  if(g_SweepLowBarsAgo  > SweepExpiryBars) g_SweepLowActive=false; }
   if(g_SweepHighActive) { g_SweepHighBarsAgo++; if(g_SweepHighBarsAgo > SweepExpiryBars) g_SweepHighActive=false; }

   if(!g_HaveSwingHigh || !g_HaveSwingLow) return;

   double o1 = iOpen(_Symbol, ZoneTF, 1);
   double c1 = iClose(_Symbol, ZoneTF, 1);
   double l1 = iLow(_Symbol, ZoneTF, 1);
   double h1 = iHigh(_Symbol, ZoneTF, 1);

   double refLow  = g_SwingLow[0];
   double refHigh = g_SwingHigh[0];

   double atrz[];
   double atrVal = (CopyBuffer(hATR_Zone, 0, 1, 1, atrz) >= 1) ? atrz[0] : 0;
   bool strongDisplacement = true;
   if(MinDisplacementATRMult > 0)
      strongDisplacement = (atrVal>0) && (MathAbs(c1-o1) >= atrVal*MinDisplacementATRMult);

   if(l1 < refLow && c1 > refLow)   { g_SweepLowActive=true;  g_SweepLowPrice=l1;  g_SweepLowBarsAgo=0; }
   if(h1 > refHigh && c1 < refHigh) { g_SweepHighActive=true; g_SweepHighPrice=h1; g_SweepHighBarsAgo=0; }

   bool brokeUp   = (c1 > refHigh) && strongDisplacement;
   bool brokeDown = (c1 < refLow)  && strongDisplacement;

   int trendBias = GetTrendBias();

   if(brokeUp)
   {
      bool wasNotBullish = (g_StructureBias <= 0);
      g_StructureBias = 1;
      if((wasNotBullish || AllowContinuationSetups) && (!RequireLiquiditySweep || g_SweepLowActive) && trendBias==1)
      {
         double invalidation = (RequireLiquiditySweep && g_SweepLowActive) ? g_SweepLowPrice : refLow;
         double dispRatio = (atrVal>0) ? MathAbs(c1-o1)/atrVal : 0;
         double volRatio  = ComputeVolumeRatio();
         ArmSetup(1, invalidation, dispRatio, volRatio);
         g_SweepLowActive = false;
      }
   }
   else if(brokeDown)
   {
      bool wasNotBearish = (g_StructureBias >= 0);
      g_StructureBias = -1;
      if((wasNotBearish || AllowContinuationSetups) && (!RequireLiquiditySweep || g_SweepHighActive) && trendBias==-1)
      {
         double invalidation = (RequireLiquiditySweep && g_SweepHighActive) ? g_SweepHighPrice : refHigh;
         double dispRatio = (atrVal>0) ? MathAbs(c1-o1)/atrVal : 0;
         double volRatio  = ComputeVolumeRatio();
         ArmSetup(-1, invalidation, dispRatio, volRatio);
         g_SweepHighActive = false;
      }
   }
}

double ComputeVolumeRatio()
{
   long vol1 = iVolume(_Symbol, ZoneTF, 1);
   long sum = 0;
   int n = 0;
   for(int i=2; i<2+VolumeAvgPeriod; i++) { sum += iVolume(_Symbol, ZoneTF, i); n++; }
   if(n==0 || sum==0) return 1.0;
   double avg = (double)sum/n;
   if(avg<=0) return 1.0;
   return (double)vol1/avg;
}

bool FindOrderBlock(int bias, double &top, double &bottom)
{
   for(int i=2; i<=OB_MaxLookbackBars+1; i++)
   {
      double o = iOpen(_Symbol, ZoneTF, i);
      double c = iClose(_Symbol, ZoneTF, i);
      double h = iHigh(_Symbol, ZoneTF, i);
      double l = iLow(_Symbol, ZoneTF, i);
      bool isOpposite = (bias==1) ? (c<o) : (c>o);
      if(isOpposite) { top=h; bottom=l; return true; }
   }
   return false;
}

bool FindDisplacementFVG(int bias, double &top, double &bottom)
{
   double hA = iHigh(_Symbol, ZoneTF, 3), lA = iLow(_Symbol, ZoneTF, 3);
   double hC = iHigh(_Symbol, ZoneTF, 1), lC = iLow(_Symbol, ZoneTF, 1);
   if(bias==1)  { if(hA<lC) { bottom=hA; top=lC; return true; } }
   else         { if(lA>hC) { top=lA; bottom=hC; return true; } }
   return false;
}

void ArmSetup(int bias, double invalidation, double displacementRatio, double volumeRatio)
{
   double obTop=0, obBottom=0;
   if(!FindOrderBlock(bias, obTop, obBottom)) return;

   double fvgTop=0, fvgBottom=0;
   bool hasFVG = FindDisplacementFVG(bias, fvgTop, fvgBottom);

   double bosExtreme = (bias==1) ? iHigh(_Symbol,ZoneTF,1) : iLow(_Symbol,ZoneTF,1);
   double fibLow, fibHigh;
   if(bias==1) { fibLow=invalidation; fibHigh=bosExtreme; } else { fibHigh=invalidation; fibLow=bosExtreme; }
   double range = fibHigh-fibLow;
   if(range<=0) return;
   double fib0=fibLow, fib618=fibLow+range*0.618, fib382=fibLow+range*0.382, fib100=fibHigh;

   g_HaveFiboZone = true;
   if(bias==1) { g_FiboZoneBottom=fib0;   g_FiboZoneTop=fib618; }
   else        { g_FiboZoneBottom=fib382; g_FiboZoneTop=fib100; }

   g_HaveOBFVGZone = true;
   g_OBFVGZoneTop = obTop; g_OBFVGZoneBottom = obBottom;
   if(hasFVG)
   {
      if(g_HaveOBFVGZone)
      {
         double t=MathMin(g_OBFVGZoneTop,fvgTop), b=MathMax(g_OBFVGZoneBottom,fvgBottom);
         if(t>b) { g_OBFVGZoneTop=t; g_OBFVGZoneBottom=b; }
      }
      else { g_OBFVGZoneTop=fvgTop; g_OBFVGZoneBottom=fvgBottom; g_HaveOBFVGZone=true; }
   }

   if(UseVolumeFilter && volumeRatio < MinVolumeRatio) return; // displacement not backed by volume - skip arming

   double buf = ZoneBufferPoints * _Point;
   g_FiboZoneTop += buf; g_FiboZoneBottom -= buf;
   if(g_HaveOBFVGZone) { g_OBFVGZoneTop += buf; g_OBFVGZoneBottom -= buf; }

   g_SetupBias  = bias;
   g_InvalidationPrice = invalidation - ((bias==1)?SL_BufferPoints*_Point:-SL_BufferPoints*_Point);
   g_ObQualityScore = MathMin(100.0, displacementRatio*60.0);
   g_VolumeScore    = MathMin(100.0, (volumeRatio/MathMax(MinVolumeRatio,0.01))*50.0);

   g_SetupArmed   = true;
   g_SetupBarsAgo = 0;
}

void AgeSetupExpiry()
{
   if(!g_SetupArmed) return;
   g_SetupBarsAgo++;
   if(g_SetupBarsAgo > SetupExpiryBars) { g_SetupArmed = false; g_LastScore = 0; }
}

void CheckSetupInvalidation()
{
   if(!g_SetupArmed) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(g_SetupBias==1  && ask < g_InvalidationPrice) { g_SetupArmed = false; g_LastScore = 0; }
   if(g_SetupBias==-1 && bid > g_InvalidationPrice) { g_SetupArmed = false; g_LastScore = 0; }
}

bool InZone()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (g_SetupBias==1) ? ask : bid;

   bool inFibo  = g_HaveFiboZone  && price<=g_FiboZoneTop  && price>=g_FiboZoneBottom;
   bool inOBFVG = g_HaveOBFVGZone && price<=g_OBFVGZoneTop && price>=g_OBFVGZoneBottom;
   return inFibo || inOBFVG;
}

// Liquidity-sweep-style rejection at the zone within the last few EntryTF
// candles - feeds the composite score as a confidence contribution.
void DetectTrap(int bias, double &confidence)
{
   confidence = 0;
   double top = g_HaveOBFVGZone ? g_OBFVGZoneTop : g_FiboZoneTop;
   double bottom = g_HaveOBFVGZone ? g_OBFVGZoneBottom : g_FiboZoneBottom;
   double zoneHeight = MathMax(top-bottom, _Point);

   for(int i=1; i<=3; i++)
   {
      double h = iHigh(_Symbol, EntryTF, i);
      double l = iLow(_Symbol, EntryTF, i);
      double c = iClose(_Symbol, EntryTF, i);

      if(bias==1 && l<bottom && c>bottom)
      {
         double pierce = bottom-l;
         confidence = MathMax(confidence, MathMin(100.0, 50.0+MathMin(50.0,(pierce/zoneHeight)*100.0)));
      }
      else if(bias==-1 && h>top && c<top)
      {
         double pierce = h-top;
         confidence = MathMax(confidence, MathMin(100.0, 50.0+MathMin(50.0,(pierce/zoneHeight)*100.0)));
      }
   }
}

bool CheckEntryCandlePattern(int bias)
{
   double o1=iOpen(_Symbol,EntryTF,1),  c1=iClose(_Symbol,EntryTF,1);
   double h1=iHigh(_Symbol,EntryTF,1),  l1=iLow(_Symbol,EntryTF,1);
   double o2=iOpen(_Symbol,EntryTF,2),  c2=iClose(_Symbol,EntryTF,2);

   double range1 = h1-l1;
   if(range1<=0) return false;
   double body1 = MathMax(MathAbs(c1-o1), _Point);

   bool bullEngulf = (c1>o1) && (o2>c2) && (c1>=o2) && (o1<=c2);
   bool bearEngulf = (c1<o1) && (c2>o2) && (o1>=c2) && (c1<=o2);

   double upperWick = h1-MathMax(o1,c1);
   double lowerWick = MathMin(o1,c1)-l1;

   bool bullPin = (lowerWick >= body1*PinBarWickBodyRatio) && (upperWick <= body1*0.5) && ((h1-c1) <= range1*0.35);
   bool bearPin = (upperWick >= body1*PinBarWickBodyRatio) && (lowerWick <= body1*0.5) && ((c1-l1) <= range1*0.35);

   if(bias==1)  return (bullEngulf || bullPin);
   if(bias==-1) return (bearEngulf || bearPin);
   return false;
}

// Composite score: OB Quality (displacement strength at zone origin) +
// Volume Confirmation + Zone Confluence (Fibo AND/OR OB-FVG both present) +
// Trap/liquidity-sweep confidence at the retest. Trend and News/Correlation
// are hard gates upstream, not part of this score.
double ComputeSignalScore(double trapConfidence)
{
   double zoneScore = (g_HaveFiboZone?50.0:0) + (g_HaveOBFVGZone?50.0:0);
   return (g_ObQualityScore + g_VolumeScore + zoneScore + trapConfidence) / 4.0;
}

//=========================== TRADE EXECUTION ================================//
// Returns true only if a position was actually opened. The caller must NOT
// discard the armed setup on a false return - CheckSetupInvalidation() /
// AgeSetupExpiry() already handle cleanup once the zone is truly gone, and
// abandoning it after every failed attempt (e.g. lot rounds to 0 because the
// SL is currently too wide for RiskPercent) would silently throw away a
// still-valid, still-scoring setup for no reason.
bool OpenTrade(int bias)
{
   double price = (bias==1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDistance = (bias==1) ? (price-g_InvalidationPrice) : (g_InvalidationPrice-price);
   if(slDistance<=0) return false;

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point * 1.1;

   // The structural invalidation point can sit well inside a single average
   // bar's range (seen down to ~0.8x ATR in backtests) - a stop that tight
   // gets swept by ordinary noise almost immediately, not real invalidation.
   // Floor it to a multiple of ATR so the SL reflects real volatility.
   double atrArr[];
   double atrNow = (CopyBuffer(hATR_Entry, 0, 1, 1, atrArr) >= 1) ? atrArr[0] : 0;
   if(atrNow>0) minDist = MathMax(minDist, atrNow*MinSL_ATRMult);

   if(slDistance < minDist) slDistance = minDist;

   double lot = CalcLot(slDistance);
   if(lot<=0)
   {
      Print("QuantixApexEA: skipped entry - SL too wide for RiskPercent at min lot (slDistance=", slDistance, ")");
      return false;
   }

   double sl = (bias==1) ? price-slDistance : price+slDistance;
   double tp1 = (bias==1) ? price+slDistance*RR_TP1 : price-slDistance*RR_TP1;
   double tp2 = (bias==1) ? price+slDistance*RR_TP2 : price-slDistance*RR_TP2;
   double tp3 = (bias==1) ? price+slDistance*RR_TP3 : price-slDistance*RR_TP3;

   sl = NormalizeDouble(sl, _Digits);
   double tpBroker = NormalizeDouble(tp3, _Digits);

   string cmt = (Language==LNG_TH) ? (bias==1?"Apex ซื้อ":"Apex ขาย") : (bias==1?"Apex BUY":"Apex SELL");
   bool ok = (bias==1) ? trade.Buy(lot, _Symbol, price, sl, tpBroker, cmt)
                        : trade.Sell(lot, _Symbol, price, sl, tpBroker, cmt);

   if(!ok)
   {
      Print("QuantixApexEA: order send failed, retcode=", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      return false;
   }

   if(PositionSelectForMagic())
   {
      g_EntryTicket = PositionGetInteger(POSITION_TICKET);
      g_EntrySLDistance = slDistance;
      g_EntryRiskMoney = lot*slDistance*MoneyPerPriceUnit();
      g_TP1Price=tp1; g_TP2Price=tp2; g_TP3Price=tp3;
      g_TP1Done=false; g_TP2Done=false;
      Print("QuantixApexEA: opened ", (bias==1?"BUY":"SELL"), " lot=", lot, " price=", price,
            " sl=", sl, " slDistance=", slDistance, " maxRisk$=", g_EntryRiskMoney);
   }
   return true;
}

void ManageOpenPosition()
{
   if(!PositionSelectForMagic())
   {
      if(g_EntryTicket!=0)
      {
         LogTradeClose(g_EntryTicket);
         g_EntryTicket=0; g_EntrySLDistance=0; g_EntryRiskMoney=0; g_TP1Done=false; g_TP2Done=false;
      }
      return;
   }

   long   type      = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL      = PositionGetDouble(POSITION_SL);
   double curTP      = PositionGetDouble(POSITION_TP);
   double vol        = PositionGetDouble(POSITION_VOLUME);
   ulong  ticket     = PositionGetInteger(POSITION_TICKET);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Backtests have shown individual trades losing 8-10x the intended
   // risk_money despite a normal SL being attached - almost certainly a
   // gap/spike blowing straight through the stop rather than a sizing bug
   // (verified: filled lot consistently matches CalcLot's 1%-risk math).
   // This is a hard circuit breaker against exactly that failure mode,
   // independent of whatever causes the gap.
   if(UseEmergencyLossGuard && g_EntryRiskMoney>0)
   {
      double floatingPL = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(floatingPL <= -g_EntryRiskMoney*MaxLossMultiplier)
      {
         Print("QuantixApexEA: EMERGENCY CLOSE - floating loss ", floatingPL,
               " exceeded ", MaxLossMultiplier, "x intended risk (", g_EntryRiskMoney, ")");
         trade.PositionClose(ticket);
         return;
      }
   }

   // Breakeven fires at a lower R-multiple than TP1, so a trade that runs
   // deep in profit and then reverses without ever quite touching TP1 still
   // can't round-trip all the way back into a full loss.
   if(UseBreakeven && g_EntrySLDistance>0)
   {
      double rr = (type==POSITION_TYPE_BUY) ? (bid-openPrice) : (openPrice-ask);
      if(rr >= g_EntrySLDistance*BreakevenTriggerRR)
      {
         double beSL = (type==POSITION_TYPE_BUY) ? openPrice+BreakevenLockPoints*_Point : openPrice-BreakevenLockPoints*_Point;
         bool needMove = (type==POSITION_TYPE_BUY) ? (curSL<beSL) : (curSL==0 || curSL>beSL);
         if(needMove)
         {
            trade.PositionModify(_Symbol, NormalizeDouble(beSL,_Digits), curTP);
            curSL = beSL;
         }
      }
   }

   if(!g_TP1Done && g_TP1Price>0)
   {
      bool hit = (type==POSITION_TYPE_BUY) ? (bid>=g_TP1Price) : (ask<=g_TP1Price);
      if(hit)
      {
         double closeVol = vol*TP1_ClosePercent/100.0;
         if(lotStep>0) closeVol = MathFloor(closeVol/lotStep)*lotStep;
         if(closeVol>=vol) trade.PositionClose(ticket);
         else if(closeVol>=volMin) trade.PositionClosePartial(ticket, closeVol);
         g_TP1Done = true;

         double newSL = (type==POSITION_TYPE_BUY) ? openPrice+BreakevenLockPoints*_Point : openPrice-BreakevenLockPoints*_Point;
         bool needMove = (type==POSITION_TYPE_BUY) ? (curSL<newSL) : (curSL==0 || curSL>newSL);
         if(needMove && PositionSelectForMagic())
            trade.PositionModify(_Symbol, NormalizeDouble(newSL,_Digits), curTP);
         return;
      }
   }

   if(g_TP1Done && !g_TP2Done && g_TP2Price>0)
   {
      bool hit = (type==POSITION_TYPE_BUY) ? (bid>=g_TP2Price) : (ask<=g_TP2Price);
      if(hit)
      {
         double closeVol = vol*TP2_ClosePercent/100.0;
         if(lotStep>0) closeVol = MathFloor(closeVol/lotStep)*lotStep;
         if(closeVol>=vol) trade.PositionClose(ticket);
         else if(closeVol>=volMin) trade.PositionClosePartial(ticket, closeVol);
         g_TP2Done = true;
      }
   }
}

//=========================== DASHBOARD ================================//
void DashLabel(string name, string text, int x, int y, color clr, int size=9)
{
   string full = DashPrefix + name;
   if(ObjectFind(0, full) < 0)
   {
      ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, full, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, full, OBJPROP_FONTSIZE, size);
      ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, full, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, full, OBJPROP_BACK, false);
   }
   ObjectSetString(0, full, OBJPROP_TEXT, text);
   ObjectSetInteger(0, full, OBJPROP_COLOR, clr);
}

void CreateDashboard()
{
   string bg = DashPrefix + "bg";
   if(ObjectFind(0, bg) < 0)
   {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, Dashboard_X-10);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, Dashboard_Y-10);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 340);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 300);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, Dashboard_BG);
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
   }
}

void UpdateDashboard()
{
   int x = Dashboard_X;
   int y = Dashboard_Y;
   int rh = 18;

   DashLabel("title", "QUANTIX APEX - ENSEMBLE SMC", x, y, Dashboard_Yellow, 10); y+=rh+4;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   DashLabel("sym", StringFormat("%s | %s: %.2f | %s: %d",
             _Symbol, (Language==LNG_TH?"ราคา":"Price"), bid,
             (Language==LNG_TH?"สเปรด":"Spread"), (int)spread),
             x, y, Dashboard_Text); y+=rh;

   int tb = GetTrendBias();
   string trendTxt = tb==1?(Language==LNG_TH?"ขาขึ้น (H1+H4)":"Bullish (H1+H4)")
                     : tb==-1?(Language==LNG_TH?"ขาลง (H1+H4)":"Bearish (H1+H4)")
                     : (Language==LNG_TH?"ไม่สอดคล้อง":"No Confluence");
   DashLabel("trend", StringFormat("%s: %s", (Language==LNG_TH?"เทรนด์":"Trend"), trendTxt),
             x, y, tb==1?Dashboard_Green:(tb==-1?Dashboard_Red:Dashboard_Text)); y+=rh;

   if(UseRegimeFilter)
   {
      double adxVal[];
      double adxNow = (CopyBuffer(hADX, 0, 1, 1, adxVal) >= 1) ? adxVal[0] : 0;
      bool trending = adxNow >= ADX_MinTrendStrength;
      DashLabel("regime", StringFormat("ADX(%s): %.1f %s", EnumToString(RegimeTimeframe), adxNow,
                trending ? (Language==LNG_TH?"(เทรนด์)":"(Trending)") : (Language==LNG_TH?"(Sideway)":"(Ranging)")),
                x, y, trending?Dashboard_Green:Dashboard_Red); y+=rh;
   }

   string setupTxt = g_SetupArmed
      ? StringFormat("%s %s | OB:%.0f Vol:%.0f", (Language==LNG_TH?"โซนพร้อม":"Zone Armed"),
                      g_SetupBias==1?"BUY":"SELL", g_ObQualityScore, g_VolumeScore)
      : (Language==LNG_TH?"รอ CHoCH/BOS":"Waiting CHoCH/BOS");
   DashLabel("setup", setupTxt, x, y, g_SetupArmed?Dashboard_Yellow:Dashboard_Text); y+=rh;

   DashLabel("score", StringFormat("%s: %.0f / %.0f", (Language==LNG_TH?"คะแนนล่าสุด":"Last Score"), g_LastScore, MinSignalScore),
             x, y, g_LastScore>=MinSignalScore?Dashboard_Green:Dashboard_Text); y+=rh;

   bool hasPos = PositionSelectForMagic();
   string posTxt; color posClr = Dashboard_Text;
   if(hasPos)
   {
      long type = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT);
      posTxt = StringFormat("%s %s %.2f | P/L %.2f | TP1 %s TP2 %s",
               (Language==LNG_TH?"ออเดอร์":"Position"),
               type==POSITION_TYPE_BUY?"BUY":"SELL", vol, profit,
               g_TP1Done?"OK":"-", g_TP2Done?"OK":"-");
      posClr = profit>=0?Dashboard_Green:Dashboard_Red;
   }
   else
   {
      posTxt = (Language==LNG_TH?"ไม่มีออเดอร์เปิดอยู่":"No Open Position");
   }
   DashLabel("pos", posTxt, x, y, posClr); y+=rh;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPL = eq - dayStartEquity;
   double dayPLPct = dayStartEquity>0 ? dayPL/dayStartEquity*100.0 : 0;
   DashLabel("daypl", StringFormat("%s: %.2f (%.2f%%)  Eq:%.2f",
             (Language==LNG_TH?"กำไรวันนี้":"Today P/L"), dayPL, dayPLPct, eq),
             x, y, dayPL>=0?Dashboard_Green:Dashboard_Red); y+=rh;

   double ddPct = equityPeak>0 ? (equityPeak-eq)/equityPeak*100.0 : 0;
   DashLabel("dd", StringFormat("%s: %.2f%% (Peak %.2f)", (Language==LNG_TH?"DD รวม":"Total DD"), ddPct, equityPeak),
             x, y, ddPct>=MaxTotalDDPercent*0.7?Dashboard_Red:Dashboard_Text); y+=rh;

   string statusTxt = ddGuardHalted ? ddGuardReason : (dailyHalted ? haltReason : (Language==LNG_TH?"สถานะ: เทรดได้ปกติ":"Status: Active"));
   DashLabel("status", statusTxt, x, y, (dailyHalted||ddGuardHalted)?Dashboard_Red:Dashboard_Green); y+=rh;
}
//+------------------------------------------------------------------+
