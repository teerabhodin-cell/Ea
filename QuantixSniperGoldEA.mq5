//+------------------------------------------------------------------+
//|                                          QuantixSniperGoldEA.mq5 |
//|   SMC/ICT Sniper Entry: Market Structure (BOS/CHoCH) + Liquidity |
//|   Sweep + Order Block / Fair Value Gap Retest for XAUUSD         |
//|   Single Shot, No Grid/Martingale                                |
//|   On-Chart Dashboard + Full Risk Management + Recovery Guard     |
//|   Recommended Timeframe: M5 - M15                                |
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
input group "===== 1. Language & Time ====="
input ENUM_LANGUAGE Language        = LNG_TH;  // Select Language (default: Thai)
input bool   UseTimer               = true;    // Time Filter (คุมเวลา)
input bool   UseLocalTime           = false;   // Use Local PC Time (อิงตามเครื่อง, ไม่ใช่ Server)
input int    StartHour              = 2;       // Start Hour (ชม.เริ่ม)
input int    StartMinute            = 0;
input int    EndHour                = 22;      // Stop Hour (ชม.หยุด)
input int    EndMinute              = 0;
input bool   UseSessionFilter       = true;    // London/NY Kill Zone Filter (คุมเฉพาะช่วง London/NY)
input int    LondonStartHour        = 8;       // London Start (GMT/UTC)
input int    LondonEndHour          = 17;      // London End
input int    NYStartHour            = 13;      // New York Start (GMT/UTC)
input int    NYEndHour              = 22;      // New York End

input group "===== 2. SMC/ICT - Market Structure ====="
input int    SwingStrength          = 5;       // Swing Fractal Strength, bars each side (ความไวจุด Swing)
input double MinDisplacementATRMult = 0.6;     // Min Breakout Candle Body vs ATR (0=off) - กรอง BOS/CHoCH ปลอม

input group "===== 3. SMC/ICT - Liquidity Sweep ====="
input bool   RequireLiquiditySweep  = true;    // Require Stop Hunt Before CHoCH (ต้องมีการล่าสภาพคล่องก่อน)
input int    SweepExpiryBars        = 10;      // Sweep Validity, bars (อายุของการล่าสภาพคล่อง)

input group "===== 4. SMC/ICT - Order Block / FVG Zone ====="
input int    OB_MaxLookbackBars     = 8;       // Max Bars Back to Find Order Block
input int    SetupExpiryBars        = 12;      // Armed Zone Validity, bars (ก่อนสัญญาณหมดอายุ)
input double ZoneBufferPoints       = 0;       // Extra Buffer around Entry Zone, pts
input double SL_BufferPoints        = 50;      // Extra Buffer beyond Invalidation, pts

input group "===== 5. Filters ====="
input int    ATR_Period             = 14;      // ATR Period
input double ATR_MinPoints          = 250;     // Min ATR, pts (กันตลาดนิ่ง)
input double ATR_MaxPoints          = 3000;    // Max ATR, pts (กันช่วงข่าวแรง)
input int    MaxSpreadPoints        = 250;     // Max Allowed Spread, pts

input group "===== 6. Risk & Money Management ====="
input double RiskPercent            = 0.5;     // Risk % of Equity per Trade
input double RR_Ratio               = 2.5;     // Take Profit = SL Distance x RR
input double MinLot                 = 0.01;    // Min Lot Cap
input double MaxLot                 = 5.0;     // Max Lot Cap
input int    Slippage               = 20;      // Max Slippage, pts
input ulong  MagicNumber            = 336699;

input group "===== 7. Trade Management ====="
input bool   UseBreakeven           = true;    // Move SL to Breakeven (คุ้มทุน)
input double BreakevenTriggerRR     = 1.0;     // Trigger at Profit = N x Risk (R-Multiple)
input double BreakevenLockPoints    = 20;      // Lock Points Beyond Entry
input bool   UseTrailingStop        = true;    // ATR Trailing Stop (เทรลตาม ATR)
input double TrailingStartRR        = 1.5;     // Start Trailing at Profit = N x Risk
input double TrailingATRMultiplier  = 1.2;     // Trailing Distance = ATR x Multiplier

input group "===== 8. Drawdown Protection ====="
input bool   UseDailyLossLimit      = true;    // Daily Loss Limit (จำกัดขาดทุนรายวัน)
input double MaxDailyLossPercent    = 3.0;     // Max Daily Loss %
input bool   UseTotalDDGuard        = true;    // Total Drawdown Guard (คุม DD สะสม)
input double MaxTotalDDPercent      = 10.0;    // Max Total DD % (from Equity Peak)
input bool   UseEquityLock          = true;    // Equity Floor Lock (ล็อคพอร์ต)
input double MinEquityLimit         = 0.0;     // Min Equity Floor (0 = off)

input group "===== 9. Recovery Mode (Defensive Risk Cut) ====="
input bool   UseRecoveryMode        = true;    // Reduce Risk after Loss Streak (ลดความเสี่ยงหลังแพ้ติด)
input int    RecoveryLossStreak     = 2;       // Consecutive Losses to Trigger
input double RecoveryRiskReduceFactor = 0.5;   // Risk Multiplier while in Recovery
input int    RecoveryCooldownTrades = 3;       // Trades before Auto-Restore (if no win)

input group "===== 10. Dashboard ====="
input bool   ShowDashboard          = true;
input bool   ShowDashboardInTester  = false;   // Show Dashboard during Strategy Tester (ปิดค่าเริ่มต้นเพื่อความเร็วตอน Backtest)
input int    Dashboard_X            = 15;
input int    Dashboard_Y            = 20;
input color  Dashboard_BG           = C'20,20,20';
input color  Dashboard_Text         = clrWhite;
input color  Dashboard_Green        = clrLimeGreen;
input color  Dashboard_Red          = clrTomato;
input color  Dashboard_Yellow       = clrGold;

//=========================== GLOBALS ================================//
int      hATR     = INVALID_HANDLE;

datetime lastBarTime   = 0;
datetime currentDay    = 0;
double   dayStartEquity= 0;
double   equityPeak    = 0;

bool     tradingHalted = false;
string   haltReason    = "";

int      consecutiveLosses = 0;
int      recoveryTradesLeft= 0;
bool     inRecoveryMode    = false;
int      totalWins         = 0;
int      totalLosses       = 0;

double   g_EntrySLDistance = 0;
ulong    g_EntryTicket     = 0;

// --- SMC/ICT market structure state ---
double   g_SwingHigh[2]      = {0,0};   // [0]=latest confirmed, [1]=previous
datetime g_SwingHighTime[2]  = {0,0};
double   g_SwingLow[2]       = {0,0};
datetime g_SwingLowTime[2]   = {0,0};
bool     g_HaveSwingHigh     = false;
bool     g_HaveSwingLow      = false;

int      g_StructureBias     = 0;       // 1 bullish, -1 bearish, 0 unknown

bool     g_SweepLowActive    = false;
double   g_SweepLowPrice     = 0;
int      g_SweepLowBarsAgo   = 0;

bool     g_SweepHighActive   = false;
double   g_SweepHighPrice    = 0;
int      g_SweepHighBarsAgo  = 0;

bool     g_SetupArmed        = false;
int      g_SetupBias         = 0;       // 1 bullish, -1 bearish
double   g_ZoneTop           = 0;
double   g_ZoneBottom        = 0;
double   g_InvalidationPrice = 0;
int      g_SetupBarsAgo      = 0;

const string DashPrefix = "QSNP_DASH_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   hATR = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(hATR==INVALID_HANDLE)
   {
      Print("QuantixSniperGoldEA: indicator handle creation failed");
      return INIT_FAILED;
   }

   equityPeak     = AccountInfoDouble(ACCOUNT_EQUITY);
   dayStartEquity = equityPeak;
   currentDay     = DayStart(TimeCurrent());

   if(EffectiveShowDashboard()) CreateDashboard();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   ObjectsDeleteAll(0, DashPrefix);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageNewDay();
   CheckDrawdownGuards();
   ManageOpenPosition();

   if(EffectiveShowDashboard()) UpdateDashboard();

   if(IsNewBar())
   {
      UpdateSwings();
      UpdateStructureAndSweeps();
   }

   CheckZoneRetestAndEnter();
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC)!=MagicNumber) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                  + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                  + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(profit < 0) consecutiveLosses++;
   else           consecutiveLosses = 0;

   if(profit >= 0) totalWins++;
   else            totalLosses++;

   if(UseRecoveryMode)
   {
      if(consecutiveLosses >= RecoveryLossStreak)
      {
         inRecoveryMode     = true;
         recoveryTradesLeft = RecoveryCooldownTrades;
      }
      else if(inRecoveryMode)
      {
         if(profit >= 0)
         {
            inRecoveryMode     = false;
            recoveryTradesLeft = 0;
         }
         else
         {
            recoveryTradesLeft--;
            if(recoveryTradesLeft<=0) inRecoveryMode = false;
         }
      }
   }

   g_EntryTicket      = 0;
   g_EntrySLDistance  = 0;
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
   tm.hour = 0; tm.min = 0; tm.sec = 0;
   return StructToTime(tm);
}

void ManageNewDay()
{
   datetime today = DayStart(TimeCurrent());
   if(today != currentDay)
   {
      currentDay     = today;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}

bool IsWithinTradingTime()
{
   datetime t = UseLocalTime ? TimeLocal() : TimeCurrent();
   MqlDateTime tm;
   TimeToStruct(t, tm);
   int curMin = tm.hour*60 + tm.min;

   if(UseTimer)
   {
      int startMin = StartHour*60 + StartMinute;
      int endMin   = EndHour*60   + EndMinute;
      bool inRange;
      if(startMin <= endMin) inRange = (curMin>=startMin && curMin<endMin);
      else                   inRange = (curMin>=startMin || curMin<endMin);
      if(!inRange) return false;
   }

   if(UseSessionFilter)
   {
      int lonS = LondonStartHour*60, lonE = LondonEndHour*60;
      int nyS  = NYStartHour*60,     nyE  = NYEndHour*60;
      bool inLondon = (curMin>=lonS && curMin<lonE);
      bool inNY     = (curMin>=nyS  && curMin<nyE);
      if(!inLondon && !inNY) return false;
   }

   return true;
}

bool PassSpreadFilter()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= MaxSpreadPoints);
}

bool PassVolatilityFilter()
{
   double atr[];
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return false;
   double atrPts = atr[0] / _Point;
   return (atrPts >= ATR_MinPoints && atrPts <= ATR_MaxPoints);
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

double CalcLotSize(double slDistance)
{
   if(slDistance<=0) return 0;

   double riskPct = RiskPercent;
   if(UseRecoveryMode && inRecoveryMode) riskPct *= RecoveryRiskReduceFactor;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riskPct / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickValue<=0) return 0;

   double lossPerLot = (slDistance/tickSize) * tickValue;
   if(lossPerLot<=0) return 0;

   double lot = riskMoney / lossPerLot;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double minLotAllowed = MathMax(MinLot, volMin);

   if(lotStep>0) lot = MathFloor(lot/lotStep) * lotStep;

   // If the structural SL is so wide that even the smallest tradable lot would
   // risk more than RiskPercent, skip the setup instead of forcing an oversized
   // position - flooring up to minLotAllowed here would silently blow past the
   // configured risk cap on wide-stop setups.
   if(lot < minLotAllowed) return 0;

   lot = MathMin(lot, MathMin(MaxLot, volMax));

   return NormalizeDouble(lot, 2);
}

//=========================== SMC / ICT ENGINE ================================//
// Confirms a swing high/low fractal at shift (SwingStrength+1): the bar that
// has just accumulated enough closed bars on both sides to be validated.
// Non-repainting - each new bar only ever examines one, never-before-checked bar.
void UpdateSwings()
{
   int n = SwingStrength;
   int checkShift = n+1;
   int total = 2*n+2;
   if(Bars(_Symbol, PERIOD_CURRENT) < total+2) return;

   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, total, high) < total) return;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, total, low) < total) return;

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

   datetime pivotTime = iTime(_Symbol, PERIOD_CURRENT, checkShift);

   if(isSwingHigh)
   {
      g_SwingHigh[1]     = g_SwingHigh[0];
      g_SwingHighTime[1] = g_SwingHighTime[0];
      g_SwingHigh[0]     = pivotHigh;
      g_SwingHighTime[0] = pivotTime;
      g_HaveSwingHigh    = true;
   }
   if(isSwingLow)
   {
      g_SwingLow[1]     = g_SwingLow[0];
      g_SwingLowTime[1] = g_SwingLowTime[0];
      g_SwingLow[0]     = pivotLow;
      g_SwingLowTime[0] = pivotTime;
      g_HaveSwingLow    = true;
   }
}

// Detects liquidity sweeps (wick beyond a swing point that closes back inside)
// and structure breaks (BOS = continuation, CHoCH = reversal after a sweep).
// A confirmed CHoCH/BOS in the sweep's direction arms an OB/FVG entry setup.
void UpdateStructureAndSweeps()
{
   if(g_SweepLowActive)
   {
      g_SweepLowBarsAgo++;
      if(g_SweepLowBarsAgo > SweepExpiryBars) g_SweepLowActive = false;
   }
   if(g_SweepHighActive)
   {
      g_SweepHighBarsAgo++;
      if(g_SweepHighBarsAgo > SweepExpiryBars) g_SweepHighActive = false;
   }
   if(g_SetupArmed)
   {
      g_SetupBarsAgo++;
      if(g_SetupBarsAgo > SetupExpiryBars) g_SetupArmed = false;
   }

   if(!g_HaveSwingHigh || !g_HaveSwingLow) return;

   double openBar1  = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double closeBar1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double lowBar1   = iLow(_Symbol, PERIOD_CURRENT, 1);
   double highBar1  = iHigh(_Symbol, PERIOD_CURRENT, 1);

   double refLow  = g_SwingLow[0];
   double refHigh = g_SwingHigh[0];

   // Only a strong, impulsive (displacement) candle is allowed to count as a
   // genuine BOS/CHoCH - a close that merely creeps past the swing level by a
   // hair is treated as noise, not a real structural break.
   bool strongDisplacement = true;
   if(MinDisplacementATRMult > 0)
   {
      double atrRef[];
      if(CopyBuffer(hATR, 0, 1, 1, atrRef) < 1) strongDisplacement = false;
      else strongDisplacement = (MathAbs(closeBar1-openBar1) >= atrRef[0]*MinDisplacementATRMult);
   }

   if(lowBar1 < refLow && closeBar1 > refLow)
   {
      g_SweepLowActive  = true;
      g_SweepLowPrice   = lowBar1;
      g_SweepLowBarsAgo = 0;
   }
   if(highBar1 > refHigh && closeBar1 < refHigh)
   {
      g_SweepHighActive  = true;
      g_SweepHighPrice   = highBar1;
      g_SweepHighBarsAgo = 0;
   }

   bool brokeUp   = (closeBar1 > refHigh) && strongDisplacement;
   bool brokeDown = (closeBar1 < refLow)  && strongDisplacement;

   if(brokeUp)
   {
      bool wasNotBullish = (g_StructureBias <= 0);
      g_StructureBias = 1;
      if(wasNotBullish && (!RequireLiquiditySweep || g_SweepLowActive))
      {
         double invalidation = (RequireLiquiditySweep && g_SweepLowActive) ? g_SweepLowPrice : refLow;
         ArmSetup(1, invalidation);
         g_SweepLowActive = false;
      }
   }
   else if(brokeDown)
   {
      bool wasNotBearish = (g_StructureBias >= 0);
      g_StructureBias = -1;
      if(wasNotBearish && (!RequireLiquiditySweep || g_SweepHighActive))
      {
         double invalidation = (RequireLiquiditySweep && g_SweepHighActive) ? g_SweepHighPrice : refHigh;
         ArmSetup(-1, invalidation);
         g_SweepHighActive = false;
      }
   }
}

// Order Block: the last opposite-colored candle before the breakout candle.
bool FindOrderBlock(int bias, double &top, double &bottom)
{
   for(int i=2; i<=OB_MaxLookbackBars+1; i++)
   {
      double o = iOpen(_Symbol, PERIOD_CURRENT, i);
      double c = iClose(_Symbol, PERIOD_CURRENT, i);
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      bool isOpposite = (bias==1) ? (c<o) : (c>o);
      if(isOpposite)
      {
         top    = h;
         bottom = l;
         return true;
      }
   }
   return false;
}

// Fair Value Gap on the displacement (breakout) candle itself: 3-bar imbalance
// between the bar two before it and the breakout bar.
bool FindDisplacementFVG(int bias, double &top, double &bottom)
{
   double highA = iHigh(_Symbol, PERIOD_CURRENT, 3);
   double lowA  = iLow(_Symbol, PERIOD_CURRENT, 3);
   double highC = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double lowC  = iLow(_Symbol, PERIOD_CURRENT, 1);

   if(bias==1)
   {
      if(highA < lowC) { bottom=highA; top=lowC; return true; }
   }
   else
   {
      if(lowA > highC) { top=lowA; bottom=highC; return true; }
   }
   return false;
}

void ArmSetup(int bias, double invalidation)
{
   double obTop=0, obBottom=0;
   if(!FindOrderBlock(bias, obTop, obBottom)) return;

   double fvgTop=0, fvgBottom=0;
   bool hasFVG = FindDisplacementFVG(bias, fvgTop, fvgBottom);

   double zoneTop = obTop, zoneBottom = obBottom;
   if(hasFVG)
   {
      double top    = MathMin(obTop, fvgTop);
      double bottom = MathMax(obBottom, fvgBottom);
      if(top > bottom) { zoneTop = top; zoneBottom = bottom; } // OB/FVG overlap = tighter, higher-quality zone
   }

   double buf = ZoneBufferPoints * _Point;
   g_ZoneTop    = zoneTop + buf;
   g_ZoneBottom = zoneBottom - buf;
   g_SetupBias  = bias;

   double slBuf = SL_BufferPoints * _Point;
   g_InvalidationPrice = (bias==1) ? MathMin(invalidation, obBottom) - slBuf
                                    : MathMax(invalidation, obTop)    + slBuf;

   g_SetupArmed   = true;
   g_SetupBarsAgo = 0;
}

// Checked every tick (not just new bar) so the exact retest touch into the
// OB/FVG zone is caught, matching sniper-style precision entries.
void CheckZoneRetestAndEnter()
{
   if(!g_SetupArmed) return;
   if(tradingHalted) return;
   if(!IsWithinTradingTime()) return;
   if(PositionSelectForMagic()) return;
   if(!PassSpreadFilter()) return;
   if(!PassVolatilityFilter()) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(g_SetupBias==1)
   {
      if(ask <= g_ZoneTop && ask >= g_ZoneBottom)
      {
         OpenSMCTrade(1);
         g_SetupArmed = false;
      }
      else if(ask < g_InvalidationPrice)
      {
         g_SetupArmed = false; // ran straight through the invalidation without a retest - setup is dead
      }
   }
   else if(g_SetupBias==-1)
   {
      if(bid >= g_ZoneBottom && bid <= g_ZoneTop)
      {
         OpenSMCTrade(-1);
         g_SetupArmed = false;
      }
      else if(bid > g_InvalidationPrice)
      {
         g_SetupArmed = false;
      }
   }
}

void OpenSMCTrade(int bias)
{
   double price = (bias==1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDistance = (bias==1) ? (price - g_InvalidationPrice) : (g_InvalidationPrice - price);
   if(slDistance<=0) return;

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point * 1.1;
   if(slDistance < minDist) slDistance = minDist;

   double lot = CalcLotSize(slDistance);
   if(lot<=0) return;

   double sl, tp;
   string cmt;
   bool ok;

   if(bias==1)
   {
      sl  = NormalizeDouble(price - slDistance, _Digits);
      tp  = NormalizeDouble(price + slDistance*RR_Ratio, _Digits);
      cmt = (Language==LNG_TH) ? "SMC ซื้อ (CHoCH+OB)" : "SMC BUY (CHoCH+OB)";
      ok  = trade.Buy(lot, _Symbol, price, sl, tp, cmt);
   }
   else
   {
      sl  = NormalizeDouble(price + slDistance, _Digits);
      tp  = NormalizeDouble(price - slDistance*RR_Ratio, _Digits);
      cmt = (Language==LNG_TH) ? "SMC ขาย (CHoCH+OB)" : "SMC SELL (CHoCH+OB)";
      ok  = trade.Sell(lot, _Symbol, price, sl, tp, cmt);
   }

   if(ok && PositionSelectForMagic())
   {
      g_EntryTicket     = PositionGetInteger(POSITION_TICKET);
      g_EntrySLDistance = slDistance;
   }
}

void ManageOpenPosition()
{
   if(!PositionSelectForMagic())
   {
      if(g_EntryTicket!=0) { g_EntryTicket=0; g_EntrySLDistance=0; }
      return;
   }

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL     = PositionGetDouble(POSITION_SL);
   double curTP     = PositionGetDouble(POSITION_TP);
   long   type      = PositionGetInteger(POSITION_TYPE);

   double refDist = (g_EntrySLDistance>0) ? g_EntrySLDistance
                     : (curSL!=0 ? MathAbs(openPrice-curSL) : 0);
   if(refDist<=0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double rr  = (type==POSITION_TYPE_BUY) ? (bid-openPrice) : (openPrice-ask);

   if(UseBreakeven && rr >= refDist*BreakevenTriggerRR)
   {
      double newSL = (type==POSITION_TYPE_BUY) ? openPrice+BreakevenLockPoints*_Point
                                                  : openPrice-BreakevenLockPoints*_Point;
      bool needMove = (type==POSITION_TYPE_BUY) ? (curSL<newSL) : (curSL>newSL || curSL==0);
      if(needMove)
      {
         trade.PositionModify(_Symbol, NormalizeDouble(newSL,_Digits), curTP);
         curSL = newSL;
      }
   }

   if(UseTrailingStop && rr >= refDist*TrailingStartRR)
   {
      double atr[];
      if(CopyBuffer(hATR, 0, 0, 1, atr) >= 1)
      {
         double trailDist = atr[0]*TrailingATRMultiplier;
         if(type==POSITION_TYPE_BUY)
         {
            double newSL = bid - trailDist;
            if(newSL > curSL) trade.PositionModify(_Symbol, NormalizeDouble(newSL,_Digits), curTP);
         }
         else
         {
            double newSL = ask + trailDist;
            if(curSL==0 || newSL < curSL) trade.PositionModify(_Symbol, NormalizeDouble(newSL,_Digits), curTP);
         }
      }
   }
}

void CheckDrawdownGuards()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > equityPeak) equityPeak = equity;

   tradingHalted = false;
   haltReason    = "";

   if(UseDailyLossLimit && dayStartEquity>0)
   {
      double dayLossPct = (dayStartEquity-equity)/dayStartEquity*100.0;
      if(dayLossPct >= MaxDailyLossPercent)
      {
         tradingHalted = true;
         haltReason = (Language==LNG_TH) ? "หยุดเทรด: ขาดทุนรายวันเกินกำหนด" : "Halted: Daily loss limit";
      }
   }

   if(!tradingHalted && UseTotalDDGuard && equityPeak>0)
   {
      double ddPct = (equityPeak-equity)/equityPeak*100.0;
      if(ddPct >= MaxTotalDDPercent)
      {
         tradingHalted = true;
         haltReason = (Language==LNG_TH) ? "หยุดเทรด: DD รวมเกินกำหนด" : "Halted: Max drawdown";
      }
   }

   if(!tradingHalted && UseEquityLock && MinEquityLimit>0 && equity<=MinEquityLimit)
   {
      tradingHalted = true;
      haltReason = (Language==LNG_TH) ? "หยุดเทรด: Equity ต่ำกว่ากำหนด" : "Halted: Equity floor";
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
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 280);
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

   DashLabel("title", "QUANTIX SNIPER XAUUSD - SMC/ICT", x, y, Dashboard_Yellow, 10); y+=rh+4;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   DashLabel("sym", StringFormat("%s  |  %s: %.2f  |  %s: %d",
             _Symbol,
             (Language==LNG_TH?"ราคา":"Price"), bid,
             (Language==LNG_TH?"สเปรด":"Spread"), (int)spread),
             x, y, Dashboard_Text); y+=rh;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   DashLabel("bal", StringFormat("%s: %.2f   %s: %.2f",
             (Language==LNG_TH?"ยอดเงิน":"Balance"), bal,
             (Language==LNG_TH?"ยอดคงเหลือ":"Equity"), eq),
             x, y, Dashboard_Text); y+=rh;

   double dayPL = eq - dayStartEquity;
   double dayPLPct = dayStartEquity>0 ? dayPL/dayStartEquity*100.0 : 0;
   DashLabel("daypl", StringFormat("%s: %.2f (%.2f%%)",
             (Language==LNG_TH?"กำไรวันนี้":"Today P/L"), dayPL, dayPLPct),
             x, y, dayPL>=0?Dashboard_Green:Dashboard_Red); y+=rh;

   double ddPct = equityPeak>0 ? (equityPeak-eq)/equityPeak*100.0 : 0;
   DashLabel("dd", StringFormat("%s: %.2f%%  (%s: %.2f)",
             (Language==LNG_TH?"DD รวม":"Total DD"), ddPct,
             (Language==LNG_TH?"จุดสูงสุด":"Peak"), equityPeak),
             x, y, ddPct>=MaxTotalDDPercent*0.7?Dashboard_Red:Dashboard_Text); y+=rh;

   string biasTxt = g_StructureBias==1 ? (Language==LNG_TH?"ขาขึ้น (Bullish)":"Bullish")
                   : g_StructureBias==-1 ? (Language==LNG_TH?"ขาลง (Bearish)":"Bearish")
                   : (Language==LNG_TH?"ไม่ชัดเจน":"Unknown");
   color biasClr = g_StructureBias==1?Dashboard_Green:(g_StructureBias==-1?Dashboard_Red:Dashboard_Text);
   DashLabel("bias", StringFormat("%s: %s", (Language==LNG_TH?"โครงสร้าง":"Structure"), biasTxt),
             x, y, biasClr); y+=rh;

   string setupTxt;
   color setupClr = Dashboard_Text;
   if(g_SetupArmed)
   {
      setupTxt = StringFormat("%s %s: %.2f - %.2f",
                 (Language==LNG_TH?"รอย้อนเข้าโซน":"Waiting Retest"),
                 g_SetupBias==1?"BUY":"SELL", g_ZoneBottom, g_ZoneTop);
      setupClr = Dashboard_Yellow;
   }
   else
   {
      setupTxt = (Language==LNG_TH?"สถานะ: รอ CHoCH/BOS":"Status: Waiting for CHoCH/BOS");
   }
   DashLabel("setup", setupTxt, x, y, setupClr); y+=rh;

   bool hasPos = PositionSelectForMagic();
   string posTxt;
   color posClr = Dashboard_Text;
   if(hasPos)
   {
      long type = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT);
      posTxt = StringFormat("%s %s %.2f | P/L %.2f",
               (Language==LNG_TH?"ออเดอร์":"Position"),
               type==POSITION_TYPE_BUY?"BUY":"SELL", vol, profit);
      posClr = profit>=0?Dashboard_Green:Dashboard_Red;
   }
   else
   {
      posTxt = (Language==LNG_TH?"ไม่มีออเดอร์เปิดอยู่":"No Open Position");
   }
   DashLabel("pos", posTxt, x, y, posClr); y+=rh;

   int totalTrades = totalWins+totalLosses;
   double winRate = totalTrades>0 ? (double)totalWins/totalTrades*100.0 : 0;
   DashLabel("stats", StringFormat("%s: %d/%d (%.1f%%)",
             (Language==LNG_TH?"ผลรวม ชนะ/แพ้":"W/L"), totalWins, totalLosses, winRate),
             x, y, Dashboard_Text); y+=rh;

   string recTxt = inRecoveryMode
                   ? StringFormat("%s (%d %s)", (Language==LNG_TH?"โหมดกู้คืน: เปิด":"Recovery: ON"),
                     recoveryTradesLeft, (Language==LNG_TH?"ไม้เหลือ":"left"))
                   : (Language==LNG_TH?"โหมดกู้คืน: ปิด":"Recovery: OFF");
   DashLabel("recovery", recTxt, x, y, inRecoveryMode?Dashboard_Yellow:Dashboard_Text); y+=rh;

   string statusTxt = tradingHalted
                      ? haltReason
                      : (Language==LNG_TH?"สถานะ: เทรดได้ปกติ":"Status: Active");
   DashLabel("status", statusTxt, x, y, tradingHalted?Dashboard_Red:Dashboard_Green); y+=rh;
}
//+------------------------------------------------------------------+
