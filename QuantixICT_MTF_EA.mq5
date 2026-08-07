//+------------------------------------------------------------------+
//|                                             QuantixICT_MTF_EA.mq5|
//|   ICT / SMC Top-Down Multi-Timeframe Waterfall:                  |
//|   H1 Trend (EMA 20/50 + HH/HL or LH/LL) -> M15 Liquidity Sweep + |
//|   CHoCH -> BOS -> Fibonacci Discount/Premium Zone (+ OB/FVG) ->  |
//|   M5 Price Action Trigger (Engulfing / Pin Bar) -> Entry         |
//|   TP1 (partial close) + TP2, Full Risk Management + Kill Switch  |
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
input ENUM_TIMEFRAMES TF_Trend      = PERIOD_H1;  // Trend Filter Timeframe
input ENUM_TIMEFRAMES TF_Zone       = PERIOD_M15; // Zone Setup Timeframe (Structure / Fibo / OB / FVG)
input ENUM_TIMEFRAMES TF_Entry      = PERIOD_M5;  // Entry Trigger Timeframe (Price Action)

input group "===== 2. Trend Filter ====="
input int    EMA_Fast               = 20;      // EMA Fast Period
input int    EMA_Slow               = 50;      // EMA Slow Period
input int    SwingStrength          = 3;       // Swing Fractal Strength, bars each side (on TF_Zone)

input group "===== 3. Liquidity Sweep & Structure (CHoCH then BOS) ====="
input int    SweepExpiryBars        = 10;      // Sweep Validity, bars (TF_Zone)
input int    ChochExpiryBars        = 15;      // CHoCH-to-BOS Window, bars (TF_Zone) - ต้องเกิด BOS ภายในกี่แท่ง
input double MinDisplacementATRMult = 0.5;     // Min Breakout Candle Body vs ATR (0=off) - กรอง CHoCH/BOS ปลอม

input group "===== 4. Zone: Fibonacci + Order Block / FVG ====="
input int    OB_MaxLookbackBars     = 8;       // Max Bars Back to Find Order Block (TF_Zone)
input int    SetupExpiryBars        = 20;      // Armed Zone Validity, bars (TF_Zone)
input double ZoneBufferPoints       = 0;       // Extra Buffer around Zones, pts
input bool   RequireBothFiboAndOB   = false;   // Require BOTH Fibo Zone AND OB/FVG (false = either one counts)

input group "===== 5. Entry Trigger (Price Action on TF_Entry) ====="
input double PinBarWickBodyRatio    = 2.0;     // Pin Bar: Wick >= Body x This Ratio
input int    MaxSpreadPoints        = 300;     // Max Allowed Spread, pts
input int    ATR_Period             = 14;      // ATR Period (TF_Entry volatility filter + TF_Zone displacement filter)
input double ATR_MinPoints          = 50;      // Min ATR (TF_Entry), pts
input double ATR_MaxPoints          = 4000;    // Max ATR (TF_Entry), pts

input group "===== 6. Session Time Filter ====="
input bool   UseSessionFilter       = true;    // Only Trade Within Allowed Hours
input bool   UseLocalTime           = false;   // Use Local PC Time
input int    StartHour              = 2;       // Start Hour
input int    StartMinute            = 0;
input int    EndHour                = 22;      // Stop Hour
input int    EndMinute              = 0;

input group "===== 7. Risk & Money Management ====="
input double RiskPercent            = 1.5;     // Risk % of Equity per Trade (1-2% แนะนำ)
input double SL_BufferPoints        = 20;      // Extra Buffer beyond Trigger Candle, pts
input double RR_TP1                 = 2.0;     // TP1 = SL Distance x RR (ปิดบางส่วน)
input double RR_TP2                 = 3.5;     // TP2 = SL Distance x RR (ส่วนที่เหลือ)
input bool   UsePartialTP1          = true;    // Close Part of Position at TP1
input double TP1_ClosePercent       = 50.0;    // % of Position to Close at TP1
input double BreakevenLockPoints    = 10;      // Lock Points Beyond Entry after TP1 (คุ้มทุนไม้ที่เหลือ)
input double MinLot                 = 0.01;    // Min Lot Cap
input double MaxLot                 = 5.0;     // Max Lot Cap
input int    Slippage               = 20;      // Max Slippage, pts
input ulong  MagicNumber            = 668899;

input group "===== 8. Drawdown Protection ====="
input bool   UseDailyLossLimit      = true;    // Daily Loss Limit
input double MaxDailyLossPercent    = 3.0;     // Max Daily Loss %
input bool   UseTotalDDGuard        = true;    // Total Drawdown Guard (Kill Switch)
input double MaxTotalDDPercent      = 10.0;    // Max Total DD % (from Equity Peak)
input bool   UseEquityLock          = true;    // Equity Floor Lock
input double MinEquityLimit         = 0.0;     // Min Equity Floor (0 = off)

input group "===== 9. Dashboard ====="
input bool   ShowDashboard          = true;
input bool   ShowDashboardInTester  = false;   // Show Dashboard during Strategy Tester
input int    Dashboard_X            = 15;
input int    Dashboard_Y            = 20;
input color  Dashboard_BG           = C'20,20,20';
input color  Dashboard_Text         = clrWhite;
input color  Dashboard_Green        = clrLimeGreen;
input color  Dashboard_Red          = clrTomato;
input color  Dashboard_Yellow       = clrGold;

//=========================== GLOBALS ================================//
int hEmaFastTrend = INVALID_HANDLE, hEmaSlowTrend = INVALID_HANDLE;
int hEmaFastZone  = INVALID_HANDLE, hEmaSlowZone  = INVALID_HANDLE;
int hATR_Zone     = INVALID_HANDLE;
int hATR_Entry    = INVALID_HANDLE;

datetime lastZoneBarTime  = 0;
datetime lastEntryBarTime = 0;
datetime currentDay       = 0;
double   dayStartEquity   = 0;
double   equityPeak       = 0;

bool     dailyHalted   = false;
string   haltReason    = "";
bool     ddGuardHalted = false;
string   ddGuardReason = "";

// --- structure state (TF_Zone) ---
double   g_SwingHigh[2]     = {0,0};
datetime g_SwingHighTime[2] = {0,0};
double   g_SwingLow[2]      = {0,0};
datetime g_SwingLowTime[2]  = {0,0};
bool     g_HaveSwingHigh = false, g_HaveSwingLow = false;
int      g_SwingHighCount = 0, g_SwingLowCount = 0;

int      g_StructureBias = 0;

bool     g_SweepLowActive = false;   double g_SweepLowPrice = 0;  int g_SweepLowBarsAgo = 0;
bool     g_SweepHighActive = false;  double g_SweepHighPrice = 0; int g_SweepHighBarsAgo = 0;

bool     g_ChochPendingBull = false; double g_ChochBull_SweepLow = 0;  int g_ChochBull_BarsAgo = 0;
bool     g_ChochPendingBear = false; double g_ChochBear_SweepHigh = 0; int g_ChochBear_BarsAgo = 0;

// --- armed zone ---
bool     g_SetupArmed = false;
int      g_SetupBias  = 0;
double   g_InvalidationPrice = 0;
int      g_SetupBarsAgo = 0;

bool     g_HaveFiboZone = false;  double g_FiboZoneTop = 0, g_FiboZoneBottom = 0;
bool     g_HaveOBFVGZone = false; double g_OBFVGZoneTop = 0, g_OBFVGZoneBottom = 0;

// --- open position TP1/TP2 tracking ---
ulong    g_EntryTicket = 0;
double   g_EntrySLDistance = 0;
double   g_TP1Price = 0, g_TP2Price = 0;
bool     g_TP1Done  = false;

const string DashPrefix = "QICT_DASH_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   hEmaFastTrend = iMA(_Symbol, TF_Trend, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlowTrend = iMA(_Symbol, TF_Trend, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hEmaFastZone  = iMA(_Symbol, TF_Zone,  EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlowZone  = iMA(_Symbol, TF_Zone,  EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hATR_Zone     = iATR(_Symbol, TF_Zone,  ATR_Period);
   hATR_Entry    = iATR(_Symbol, TF_Entry, ATR_Period);

   if(hEmaFastTrend==INVALID_HANDLE || hEmaSlowTrend==INVALID_HANDLE ||
      hEmaFastZone==INVALID_HANDLE  || hEmaSlowZone==INVALID_HANDLE  ||
      hATR_Zone==INVALID_HANDLE     || hATR_Entry==INVALID_HANDLE)
   {
      Print("QuantixICT_MTF_EA: indicator handle creation failed");
      return INIT_FAILED;
   }

   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   equityPeak     = dayStartEquity;
   currentDay     = DayStart(TimeCurrent());

   if(EffectiveShowDashboard()) CreateDashboard();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEmaFastTrend!=INVALID_HANDLE) IndicatorRelease(hEmaFastTrend);
   if(hEmaSlowTrend!=INVALID_HANDLE) IndicatorRelease(hEmaSlowTrend);
   if(hEmaFastZone!=INVALID_HANDLE)  IndicatorRelease(hEmaFastZone);
   if(hEmaSlowZone!=INVALID_HANDLE)  IndicatorRelease(hEmaSlowZone);
   if(hATR_Zone!=INVALID_HANDLE)     IndicatorRelease(hATR_Zone);
   if(hATR_Entry!=INVALID_HANDLE)    IndicatorRelease(hATR_Entry);
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
   if(PositionSelectForMagic()) return; // one at a time
   if(!IsNewEntryBar()) return;
   if(!IsWithinSession()) return;
   if(!PassSpreadFilter()) return;
   if(!PassVolatilityFilter()) return;
   if(!InZone()) return;
   if(!CheckEntryCandlePattern(g_SetupBias)) return;

   OpenTrade(g_SetupBias);
   g_SetupArmed = false;
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
   datetime t = iTime(_Symbol, TF_Zone, 0);
   if(t != lastZoneBarTime) { lastZoneBarTime = t; return true; }
   return false;
}

bool IsNewEntryBar()
{
   datetime t = iTime(_Symbol, TF_Entry, 0);
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

double CalcLot(double slDistance)
{
   if(slDistance<=0) return 0;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * RiskPercent / 100.0;
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
   if(lot < minLotAllowed) return 0; // SL too wide for target risk at min lot - skip rather than over-risk

   lot = MathMin(lot, MathMin(MaxLot, volMax));
   return NormalizeDouble(lot, 2);
}

//=========================== STRUCTURE ENGINE (TF_Zone) ================================//
void UpdateSwings()
{
   int n = SwingStrength;
   int checkShift = n+1;
   int total = 2*n+2;
   if(Bars(_Symbol, TF_Zone) < total+2) return;

   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyHigh(_Symbol, TF_Zone, 0, total, high) < total) return;
   if(CopyLow(_Symbol, TF_Zone, 0, total, low) < total) return;

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

   datetime pivotTime = iTime(_Symbol, TF_Zone, checkShift);

   if(isSwingHigh)
   {
      g_SwingHigh[1]     = g_SwingHigh[0];
      g_SwingHighTime[1] = g_SwingHighTime[0];
      g_SwingHigh[0]     = pivotHigh;
      g_SwingHighTime[0] = pivotTime;
      g_HaveSwingHigh    = true;
      if(g_SwingHighCount<2) g_SwingHighCount++;
   }
   if(isSwingLow)
   {
      g_SwingLow[1]     = g_SwingLow[0];
      g_SwingLowTime[1] = g_SwingLowTime[0];
      g_SwingLow[0]     = pivotLow;
      g_SwingLowTime[0] = pivotTime;
      g_HaveSwingLow    = true;
      if(g_SwingLowCount<2) g_SwingLowCount++;
   }
}

bool IsHH_HL()
{
   return g_SwingHighCount>=2 && g_SwingLowCount>=2 &&
          g_SwingHigh[0]>g_SwingHigh[1] && g_SwingLow[0]>g_SwingLow[1];
}

bool IsLH_LL()
{
   return g_SwingHighCount>=2 && g_SwingLowCount>=2 &&
          g_SwingHigh[0]<g_SwingHigh[1] && g_SwingLow[0]<g_SwingLow[1];
}

// Step 1: Trend Filter - EMA20/50 must agree on BOTH TF_Trend (H1) and TF_Zone (M15),
// AND the confirmed swing sequence on TF_Zone must show HH+HL (bullish) or LH+LL (bearish).
int GetTrendBias()
{
   double fastH[], slowH[], fastZ[], slowZ[];
   if(CopyBuffer(hEmaFastTrend, 0, 1, 1, fastH) < 1) return 0;
   if(CopyBuffer(hEmaSlowTrend, 0, 1, 1, slowH) < 1) return 0;
   if(CopyBuffer(hEmaFastZone,  0, 1, 1, fastZ) < 1) return 0;
   if(CopyBuffer(hEmaSlowZone,  0, 1, 1, slowZ) < 1) return 0;

   int biasH = fastH[0]>slowH[0] ? 1 : (fastH[0]<slowH[0] ? -1 : 0);
   int biasZ = fastZ[0]>slowZ[0] ? 1 : (fastZ[0]<slowZ[0] ? -1 : 0);
   if(biasH==0 || biasZ==0 || biasH!=biasZ) return 0;

   if(biasH==1  && !IsHH_HL()) return 0;
   if(biasH==-1 && !IsLH_LL()) return 0;

   return biasH;
}

// Steps 2-3: Liquidity Sweep -> CHoCH -> BOS, strictly sequential per direction.
// A CHoCH (bias flip) requires its own sweep; the following BOS (continuation)
// requires ANOTHER sweep of the intervening pullback point, within ChochExpiryBars.
// Only once both fire in order does the Fibo/OB/FVG zone get armed.
void UpdateStructureAndSweeps()
{
   if(g_SweepLowActive)  { g_SweepLowBarsAgo++;  if(g_SweepLowBarsAgo  > SweepExpiryBars) g_SweepLowActive=false; }
   if(g_SweepHighActive) { g_SweepHighBarsAgo++; if(g_SweepHighBarsAgo > SweepExpiryBars) g_SweepHighActive=false; }
   if(g_ChochPendingBull){ g_ChochBull_BarsAgo++; if(g_ChochBull_BarsAgo > ChochExpiryBars) g_ChochPendingBull=false; }
   if(g_ChochPendingBear){ g_ChochBear_BarsAgo++; if(g_ChochBear_BarsAgo > ChochExpiryBars) g_ChochPendingBear=false; }

   if(!g_HaveSwingHigh || !g_HaveSwingLow) return;

   double o1 = iOpen(_Symbol, TF_Zone, 1);
   double c1 = iClose(_Symbol, TF_Zone, 1);
   double l1 = iLow(_Symbol, TF_Zone, 1);
   double h1 = iHigh(_Symbol, TF_Zone, 1);

   double refLow  = g_SwingLow[0];
   double refHigh = g_SwingHigh[0];

   bool strongDisplacement = true;
   if(MinDisplacementATRMult > 0)
   {
      double atrz[];
      if(CopyBuffer(hATR_Zone, 0, 1, 1, atrz) < 1) strongDisplacement = false;
      else strongDisplacement = (MathAbs(c1-o1) >= atrz[0]*MinDisplacementATRMult);
   }

   if(l1 < refLow && c1 > refLow)   { g_SweepLowActive=true;  g_SweepLowPrice=l1;  g_SweepLowBarsAgo=0; }
   if(h1 > refHigh && c1 < refHigh) { g_SweepHighActive=true; g_SweepHighPrice=h1; g_SweepHighBarsAgo=0; }

   bool brokeUp   = (c1 > refHigh) && strongDisplacement;
   bool brokeDown = (c1 < refLow)  && strongDisplacement;

   int trendBias = GetTrendBias();

   if(brokeUp)
   {
      bool wasNotBullish = (g_StructureBias <= 0);
      g_StructureBias = 1;

      if(wasNotBullish && g_SweepLowActive && trendBias==1)
      {
         g_ChochPendingBull   = true;
         g_ChochBull_SweepLow = g_SweepLowPrice;
         g_ChochBull_BarsAgo  = 0;
         g_ChochPendingBear   = false;
         g_SweepLowActive     = false;
      }
      else if(!wasNotBullish && g_ChochPendingBull && g_SweepLowActive && trendBias==1)
      {
         ArmZone(1, g_ChochBull_SweepLow, h1);
         g_ChochPendingBull = false;
         g_SweepLowActive   = false;
      }
   }
   else if(brokeDown)
   {
      bool wasNotBearish = (g_StructureBias >= 0);
      g_StructureBias = -1;

      if(wasNotBearish && g_SweepHighActive && trendBias==-1)
      {
         g_ChochPendingBear    = true;
         g_ChochBear_SweepHigh = g_SweepHighPrice;
         g_ChochBear_BarsAgo   = 0;
         g_ChochPendingBull    = false;
         g_SweepHighActive     = false;
      }
      else if(!wasNotBearish && g_ChochPendingBear && g_SweepHighActive && trendBias==-1)
      {
         ArmZone(-1, g_ChochBear_SweepHigh, l1);
         g_ChochPendingBear = false;
         g_SweepHighActive  = false;
      }
   }
}

// Order Block: last opposite-colored TF_Zone candle before the BOS candle.
bool FindOrderBlockZone(int bias, double &top, double &bottom)
{
   for(int i=2; i<=OB_MaxLookbackBars+1; i++)
   {
      double o = iOpen(_Symbol, TF_Zone, i);
      double c = iClose(_Symbol, TF_Zone, i);
      double h = iHigh(_Symbol, TF_Zone, i);
      double l = iLow(_Symbol, TF_Zone, i);
      bool isOpposite = (bias==1) ? (c<o) : (c>o);
      if(isOpposite) { top=h; bottom=l; return true; }
   }
   return false;
}

// FVG on the BOS (displacement) candle itself: 3-bar imbalance.
bool FindDisplacementFVG(int bias, double &top, double &bottom)
{
   double hA = iHigh(_Symbol, TF_Zone, 3), lA = iLow(_Symbol, TF_Zone, 3);
   double hC = iHigh(_Symbol, TF_Zone, 1), lC = iLow(_Symbol, TF_Zone, 1);
   if(bias==1)  { if(hA<lC) { bottom=hA; top=lC; return true; } }
   else         { if(lA>hC) { top=lA; bottom=hC; return true; } }
   return false;
}

// Step 4: Zone Identification. Fibo range = sweep point (0%) -> BOS extreme (100%).
// Qualifying band = Discount(0-50%) union OTE(38.2-61.8%) for buys = effectively
// [0%, 61.8%]; mirror [38.2%, 100%] for sells. Combined with OB/FVG per
// RequireBothFiboAndOB (AND) or either-one (OR, default).
void ArmZone(int bias, double sweepPrice, double bosExtremePrice)
{
   double fibLow, fibHigh;
   if(bias==1) { fibLow=sweepPrice; fibHigh=bosExtremePrice; }
   else        { fibHigh=sweepPrice; fibLow=bosExtremePrice; }

   double range = fibHigh - fibLow;
   if(range<=0) return;

   double fib0 = fibLow, fib382 = fibLow+range*0.382, fib618 = fibLow+range*0.618, fib100 = fibHigh;

   g_HaveFiboZone = true;
   if(bias==1) { g_FiboZoneBottom = fib0;   g_FiboZoneTop = fib618; }
   else        { g_FiboZoneBottom = fib382; g_FiboZoneTop = fib100; }

   double obTop=0, obBottom=0;
   bool hasOB = FindOrderBlockZone(bias, obTop, obBottom);
   double fvgTop=0, fvgBottom=0;
   bool hasFVG = FindDisplacementFVG(bias, fvgTop, fvgBottom);

   g_HaveOBFVGZone = false;
   if(hasOB) { g_OBFVGZoneTop=obTop; g_OBFVGZoneBottom=obBottom; g_HaveOBFVGZone=true; }
   if(hasFVG)
   {
      if(g_HaveOBFVGZone)
      {
         double t=MathMin(g_OBFVGZoneTop,fvgTop), b=MathMax(g_OBFVGZoneBottom,fvgBottom);
         if(t>b) { g_OBFVGZoneTop=t; g_OBFVGZoneBottom=b; } // overlap = tighter zone
      }
      else { g_OBFVGZoneTop=fvgTop; g_OBFVGZoneBottom=fvgBottom; g_HaveOBFVGZone=true; }
   }

   if(RequireBothFiboAndOB && !g_HaveOBFVGZone) return; // can't satisfy AND - don't arm

   g_SetupBias         = bias;
   g_InvalidationPrice = sweepPrice;
   g_SetupArmed         = true;
   g_SetupBarsAgo        = 0;
}

void AgeSetupExpiry()
{
   if(!g_SetupArmed) return;
   g_SetupBarsAgo++;
   if(g_SetupBarsAgo > SetupExpiryBars) g_SetupArmed = false;
}

void CheckSetupInvalidation()
{
   if(!g_SetupArmed) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(g_SetupBias==1  && ask < g_InvalidationPrice) g_SetupArmed = false;
   if(g_SetupBias==-1 && bid > g_InvalidationPrice) g_SetupArmed = false;
}

bool InZone()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (g_SetupBias==1) ? ask : bid;
   double buf = ZoneBufferPoints*_Point;

   bool inFibo  = g_HaveFiboZone  && price<=g_FiboZoneTop+buf   && price>=g_FiboZoneBottom-buf;
   bool inOBFVG = g_HaveOBFVGZone && price<=g_OBFVGZoneTop+buf  && price>=g_OBFVGZoneBottom-buf;

   if(RequireBothFiboAndOB) return inFibo && inOBFVG;
   return inFibo || inOBFVG;
}

//=========================== ENTRY TRIGGER (TF_Entry) ================================//
// Bullish Engulfing / Pin Bar for BUY; mirror Bearish patterns for SELL.
// Uses only the last CLOSED TF_Entry candle - non-repainting.
bool CheckEntryCandlePattern(int bias)
{
   double o1 = iOpen(_Symbol, TF_Entry, 1),  c1 = iClose(_Symbol, TF_Entry, 1);
   double h1 = iHigh(_Symbol, TF_Entry, 1),  l1 = iLow(_Symbol, TF_Entry, 1);
   double o2 = iOpen(_Symbol, TF_Entry, 2),  c2 = iClose(_Symbol, TF_Entry, 2);

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

void OpenTrade(int bias)
{
   double l1 = iLow(_Symbol, TF_Entry, 1);
   double h1 = iHigh(_Symbol, TF_Entry, 1);

   double price = (bias==1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (bias==1) ? l1-SL_BufferPoints*_Point : h1+SL_BufferPoints*_Point;

   double slDistance = MathAbs(price-sl);
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point * 1.1;
   if(slDistance < minDist)
   {
      slDistance = minDist;
      sl = (bias==1) ? price-slDistance : price+slDistance;
   }

   double lot = CalcLot(slDistance);
   if(lot<=0) return;

   double tp1 = (bias==1) ? price+slDistance*RR_TP1 : price-slDistance*RR_TP1;
   double tp2 = (bias==1) ? price+slDistance*RR_TP2 : price-slDistance*RR_TP2;

   sl = NormalizeDouble(sl, _Digits);
   double tpBroker = NormalizeDouble(tp2, _Digits); // broker-side TP = far target; TP1 handled manually as a partial close

   string cmt = (Language==LNG_TH) ? (bias==1?"ICT MTF ซื้อ":"ICT MTF ขาย")
                                     : (bias==1?"ICT MTF BUY":"ICT MTF SELL");

   bool ok = (bias==1) ? trade.Buy(lot, _Symbol, price, sl, tpBroker, cmt)
                        : trade.Sell(lot, _Symbol, price, sl, tpBroker, cmt);

   if(ok && PositionSelectForMagic())
   {
      g_EntryTicket     = PositionGetInteger(POSITION_TICKET);
      g_EntrySLDistance = slDistance;
      g_TP1Price = tp1;
      g_TP2Price = tp2;
      g_TP1Done  = false;
   }
}

void ManageOpenPosition()
{
   if(!PositionSelectForMagic())
   {
      if(g_EntryTicket!=0) { g_EntryTicket=0; g_EntrySLDistance=0; g_TP1Done=false; }
      return;
   }

   long   type      = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL     = PositionGetDouble(POSITION_SL);
   double curTP     = PositionGetDouble(POSITION_TP);
   double vol       = PositionGetDouble(POSITION_VOLUME);
   ulong  ticket    = PositionGetInteger(POSITION_TICKET);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(UsePartialTP1 && !g_TP1Done && g_TP1Price>0)
   {
      bool hitTP1 = (type==POSITION_TYPE_BUY) ? (bid>=g_TP1Price) : (ask<=g_TP1Price);
      if(hitTP1)
      {
         double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double closeVol = vol * TP1_ClosePercent/100.0;
         if(lotStep>0) closeVol = MathFloor(closeVol/lotStep) * lotStep;

         if(closeVol >= vol) trade.PositionClose(ticket);
         else if(closeVol >= volMin) trade.PositionClosePartial(ticket, closeVol);

         g_TP1Done = true;

         double newSL = (type==POSITION_TYPE_BUY) ? openPrice+BreakevenLockPoints*_Point : openPrice-BreakevenLockPoints*_Point;
         bool needMove = (type==POSITION_TYPE_BUY) ? (curSL<newSL) : (curSL==0 || curSL>newSL);
         if(needMove && PositionSelectForMagic())
            trade.PositionModify(_Symbol, NormalizeDouble(newSL,_Digits), curTP);
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
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 360);
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

   DashLabel("title", "QUANTIX ICT MTF - H1/M15/M5 WATERFALL", x, y, Dashboard_Yellow, 10); y+=rh+4;

   int trendBias = GetTrendBias();
   string trendTxt = trendBias==1 ? (Language==LNG_TH?"ขาขึ้น (HH/HL)":"Bullish (HH/HL)")
                     : trendBias==-1 ? (Language==LNG_TH?"ขาลง (LH/LL)":"Bearish (LH/LL)")
                     : (Language==LNG_TH?"ไม่ชัดเจน":"No Alignment");
   color trendClr = trendBias==1?Dashboard_Green:(trendBias==-1?Dashboard_Red:Dashboard_Text);
   DashLabel("trend", StringFormat("%s: %s", (Language==LNG_TH?"เทรนด์ H1+M15":"Trend H1+M15"), trendTxt), x, y, trendClr); y+=rh;

   string chochTxt = g_ChochPendingBull ? (Language==LNG_TH?"CHoCH ขึ้น รอ BOS":"CHoCH Up, waiting BOS")
                     : g_ChochPendingBear ? (Language==LNG_TH?"CHoCH ลง รอ BOS":"CHoCH Down, waiting BOS")
                     : (Language==LNG_TH?"ไม่มี CHoCH ค้าง":"No pending CHoCH");
   DashLabel("choch", chochTxt, x, y, (g_ChochPendingBull||g_ChochPendingBear)?Dashboard_Yellow:Dashboard_Text); y+=rh;

   string setupTxt;
   color setupClr = Dashboard_Text;
   if(g_SetupArmed)
   {
      setupTxt = StringFormat("%s %s | Fibo %.2f-%.2f",
                 (Language==LNG_TH?"โซนพร้อม":"Zone Armed"),
                 g_SetupBias==1?"BUY":"SELL", g_FiboZoneBottom, g_FiboZoneTop);
      setupClr = Dashboard_Yellow;
   }
   else
   {
      setupTxt = (Language==LNG_TH?"สถานะ: รอ CHoCH -> BOS":"Status: Waiting CHoCH -> BOS");
   }
   DashLabel("setup", setupTxt, x, y, setupClr); y+=rh;

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

   bool hasPos = PositionSelectForMagic();
   string posTxt; color posClr = Dashboard_Text;
   if(hasPos)
   {
      long type = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT);
      posTxt = StringFormat("%s %s %.2f | P/L %.2f | TP1 %s",
               (Language==LNG_TH?"ออเดอร์":"Position"),
               type==POSITION_TYPE_BUY?"BUY":"SELL", vol, profit,
               g_TP1Done?(Language==LNG_TH?"เก็บแล้ว":"Taken"):(Language==LNG_TH?"รออยู่":"Pending"));
      posClr = profit>=0?Dashboard_Green:Dashboard_Red;
   }
   else
   {
      posTxt = (Language==LNG_TH?"ไม่มีออเดอร์เปิดอยู่":"No Open Position");
   }
   DashLabel("pos", posTxt, x, y, posClr); y+=rh;

   string statusTxt = ddGuardHalted ? ddGuardReason : (dailyHalted ? haltReason : (Language==LNG_TH?"สถานะ: เทรดได้ปกติ":"Status: Active"));
   DashLabel("status", statusTxt, x, y, (dailyHalted||ddGuardHalted)?Dashboard_Red:Dashboard_Green); y+=rh;
}
//+------------------------------------------------------------------+
