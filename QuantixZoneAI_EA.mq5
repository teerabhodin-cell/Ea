//+------------------------------------------------------------------+
//|                                            QuantixZoneAI_EA.mq5  |
//|   Multi-Timeframe Supply/Demand Zone AI:                         |
//|   Detects Supply & Demand zones on M15/M30/H1/H4 (origin base    |
//|   before a strong displacement move), scores a composite         |
//|   Trend + Momentum + Zone-Confluence + Trap(liquidity-sweep)     |
//|   signal, enters on a confirming candle at the nearest same-side |
//|   zone, and ladders TP1/TP2/TP3 across the next opposing zones.  |
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
input ENUM_TIMEFRAMES EntryTimeframe = PERIOD_M5;  // Entry / Trap-Confirmation Timeframe
input ENUM_TIMEFRAMES TrendTimeframe = PERIOD_H4;  // Trend Bias Timeframe

input group "===== 2. Zone Detection (M15/M30/H1/H4) ====="
input int    ATR_Period             = 14;      // ATR Period (per zone timeframe)
input double ZoneDisplacementATRMult = 1.0;    // Min Displacement Candle Body vs ATR (defines a zone origin)
input int    MaxZoneLookbackBars    = 40;      // Max Bars Back to Find Each Zone

input group "===== 3. Trend & Momentum ====="
input int    EMA_TrendPeriod        = 50;      // EMA Period on TrendTimeframe
input int    RSI_Period             = 14;      // RSI Period on EntryTimeframe

input group "===== 4. Trap (Liquidity Sweep) Confirmation ====="
input bool   UseTrapFilter          = true;    // Require a Trap/Rejection at the Zone
input int    TrapLookbackBars       = 3;       // Bars Back on EntryTimeframe to Look for a Trap

input group "===== 5. Entry Candle Confirmation ====="
input double PinBarWickBodyRatio    = 2.0;     // Pin Bar: Wick >= Body x This Ratio

input group "===== 6. Smart Signal Score ====="
input double MinSignalScore         = 60.0;    // Min Composite Score (0-100) to Trade

input group "===== 7. Risk & Money Management ====="
input double RiskPercent            = 1.0;     // Risk % of Equity per Trade
input double SL_BufferPoints        = 30;      // Extra Buffer beyond Origin Zone, pts
input double RR_Fallback1           = 1.0;     // TP1 Fallback RR (if no target zone found)
input double RR_Fallback2           = 2.0;     // TP2 Fallback RR
input double RR_Fallback3           = 3.0;     // TP3 Fallback RR
input bool   UsePartialTP           = true;    // Scale Out at TP1/TP2
input double TP1_ClosePercent       = 33.0;    // % of Position to Close at TP1
input double TP2_ClosePercent       = 33.0;    // % of Remaining Position to Close at TP2
input double BreakevenLockPoints    = 10;      // Lock Points Beyond Entry after TP1
input double MinLot                 = 0.01;    // Min Lot Cap
input double MaxLot                 = 5.0;     // Max Lot Cap
input int    Slippage               = 20;      // Max Slippage, pts
input ulong  MagicNumber            = 882255;

input group "===== 8. Filters ====="
input int    MaxSpreadPoints        = 300;     // Max Allowed Spread, pts
input bool   UseSessionFilter       = true;    // Only Trade Within Allowed Hours
input bool   UseLocalTime           = false;   // Use Local PC Time
input int    StartHour              = 2;       // Start Hour
input int    StartMinute            = 0;
input int    EndHour                = 22;      // Stop Hour
input int    EndMinute              = 0;

input group "===== 9. Drawdown Protection ====="
input bool   UseDailyLossLimit      = true;    // Daily Loss Limit
input double MaxDailyLossPercent    = 3.0;     // Max Daily Loss %
input bool   UseTotalDDGuard        = true;    // Total Drawdown Guard (Kill Switch)
input double MaxTotalDDPercent      = 10.0;    // Max Total DD % (from Equity Peak)
input bool   UseEquityLock          = true;    // Equity Floor Lock
input double MinEquityLimit         = 0.0;     // Min Equity Floor (0 = off)

input group "===== 10. Dashboard ====="
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
#define ZONE_TF_COUNT 4
ENUM_TIMEFRAMES g_ZoneTF[ZONE_TF_COUNT];
string          g_ZoneTFName[ZONE_TF_COUNT] = {"M15","M30","H1","H4"};
int             g_hATR_Zone[ZONE_TF_COUNT];
int             hEmaTrend  = INVALID_HANDLE;
int             hRSI_Entry = INVALID_HANDLE;

double g_SupplyTop[ZONE_TF_COUNT], g_SupplyBottom[ZONE_TF_COUNT]; bool g_SupplyValid[ZONE_TF_COUNT];
double g_DemandTop[ZONE_TF_COUNT], g_DemandBottom[ZONE_TF_COUNT]; bool g_DemandValid[ZONE_TF_COUNT];

datetime lastZoneBarTime  = 0;
datetime lastEntryBarTime = 0;
datetime currentDay       = 0;
double   dayStartEquity   = 0;
double   equityPeak       = 0;

bool     dailyHalted   = false;
string   haltReason    = "";
bool     ddGuardHalted = false;
string   ddGuardReason = "";

int      g_TrendBias      = 0;
double   g_LastScore      = 0;

ulong    g_EntryTicket = 0;
double   g_TP1Price = 0, g_TP2Price = 0, g_TP3Price = 0;
bool     g_TP1Done = false, g_TP2Done = false;

const string DashPrefix = "QZAI_DASH_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_ZoneTF[0]=PERIOD_M15; g_ZoneTF[1]=PERIOD_M30; g_ZoneTF[2]=PERIOD_H1; g_ZoneTF[3]=PERIOD_H4;

   for(int i=0;i<ZONE_TF_COUNT;i++)
   {
      g_hATR_Zone[i] = iATR(_Symbol, g_ZoneTF[i], ATR_Period);
      if(g_hATR_Zone[i]==INVALID_HANDLE)
      {
         Print("QuantixZoneAI_EA: ATR handle failed for ", g_ZoneTFName[i]);
         return INIT_FAILED;
      }
   }

   hEmaTrend  = iMA(_Symbol, TrendTimeframe, EMA_TrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_Entry = iRSI(_Symbol, EntryTimeframe, RSI_Period, PRICE_CLOSE);

   if(hEmaTrend==INVALID_HANDLE || hRSI_Entry==INVALID_HANDLE)
   {
      Print("QuantixZoneAI_EA: indicator handle creation failed");
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
   for(int i=0;i<ZONE_TF_COUNT;i++)
      if(g_hATR_Zone[i]!=INVALID_HANDLE) IndicatorRelease(g_hATR_Zone[i]);
   if(hEmaTrend!=INVALID_HANDLE)  IndicatorRelease(hEmaTrend);
   if(hRSI_Entry!=INVALID_HANDLE) IndicatorRelease(hRSI_Entry);
   ObjectsDeleteAll(0, DashPrefix);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageNewDay();
   ManageOpenPosition();
   CheckDailyLimits();
   CheckTotalDDGuard();

   if(EffectiveShowDashboard()) UpdateDashboard();

   if(dailyHalted || ddGuardHalted) return;

   if(IsNewZoneBar()) UpdateAllZones();

   if(PositionSelectForMagic()) return; // one at a time
   if(!IsNewEntryBar()) return;
   if(!IsWithinSession()) return;
   if(!PassSpreadFilter()) return;

   g_TrendBias = GetTrendBias();
   if(g_TrendBias==0) return;

   double top=0, bottom=0; string tfLabel="";
   if(!FindTouchedOriginZone(g_TrendBias, top, bottom, tfLabel)) return;
   if(!CheckEntryCandlePattern(g_TrendBias)) return;

   bool trapOK = true;
   double trapConf = 0;
   if(UseTrapFilter)
      trapOK = DetectTrap(g_TrendBias, top, bottom, trapConf);
   if(!trapOK) return;

   double score = ComputeSignalScore(g_TrendBias, trapConf);
   g_LastScore = score;
   if(score < MinSignalScore) return;

   OpenTrade(g_TrendBias, top, bottom);
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
   datetime t = iTime(_Symbol, PERIOD_M15, 0); // fastest of the 4 zone timeframes
   if(t != lastZoneBarTime) { lastZoneBarTime = t; return true; }
   return false;
}

bool IsNewEntryBar()
{
   datetime t = iTime(_Symbol, EntryTimeframe, 0);
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

//=========================== ZONE ENGINE ================================//
// A zone's "origin" is the base candle right before a strong displacement
// move away from it - i.e. the same idea as an Order Block, just computed
// independently per timeframe and labeled Supply (bearish origin) / Demand
// (bullish origin) to match how Supply & Demand zone trading is taught.
bool FindZone(int tfIdx, bool findSupply, double &top, double &bottom)
{
   ENUM_TIMEFRAMES tf = g_ZoneTF[tfIdx];
   for(int i=1; i<=MaxZoneLookbackBars; i++)
   {
      double o = iOpen(_Symbol, tf, i);
      double c = iClose(_Symbol, tf, i);

      double atrArr[];
      if(CopyBuffer(g_hATR_Zone[tfIdx], 0, i, 1, atrArr) < 1) continue;
      double atrVal = atrArr[0];
      if(atrVal<=0) continue;

      bool isDisplacement = MathAbs(c-o) >= atrVal*ZoneDisplacementATRMult;
      bool matchesDir = findSupply ? (c<o) : (c>o); // Supply = sold off from there; Demand = rallied from there

      if(isDisplacement && matchesDir)
      {
         top    = iHigh(_Symbol, tf, i+1);
         bottom = iLow(_Symbol, tf, i+1);
         return true;
      }
   }
   return false;
}

void UpdateAllZones()
{
   for(int i=0;i<ZONE_TF_COUNT;i++)
   {
      g_SupplyValid[i] = FindZone(i, true,  g_SupplyTop[i], g_SupplyBottom[i]);
      g_DemandValid[i] = FindZone(i, false, g_DemandTop[i], g_DemandBottom[i]);
   }
}

int GetTrendBias()
{
   double ema[];
   if(CopyBuffer(hEmaTrend, 0, 1, 1, ema) < 1) return 0;
   double c = iClose(_Symbol, TrendTimeframe, 1);
   if(c > ema[0]) return 1;
   if(c < ema[0]) return -1;
   return 0;
}

// Finds the nearest-tier same-direction zone that the last closed
// EntryTimeframe candle overlaps (price currently testing/bouncing off it).
bool FindTouchedOriginZone(int bias, double &top, double &bottom, string &tfLabel)
{
   double low1  = iLow(_Symbol, EntryTimeframe, 1);
   double high1 = iHigh(_Symbol, EntryTimeframe, 1);

   for(int i=0;i<ZONE_TF_COUNT;i++)
   {
      bool valid = (bias==1) ? g_DemandValid[i] : g_SupplyValid[i];
      if(!valid) continue;
      double t = (bias==1) ? g_DemandTop[i] : g_SupplyTop[i];
      double b = (bias==1) ? g_DemandBottom[i] : g_SupplyBottom[i];

      bool overlaps = !(high1<b || low1>t); // candle range intersects zone range
      if(overlaps)
      {
         top=t; bottom=b; tfLabel=g_ZoneTFName[i];
         return true;
      }
   }
   return false;
}

// S-TRAP / B-TRAP: within the last few EntryTimeframe candles, price wicked
// beyond the zone's far edge and closed back inside - a liquidity-sweep-style
// rejection. Confidence scales with how deep the wick pierced relative to
// the zone's own height.
bool DetectTrap(int bias, double zoneTop, double zoneBottom, double &confidence)
{
   double zoneHeight = MathMax(zoneTop-zoneBottom, _Point);
   confidence = 0;

   for(int i=1; i<=TrapLookbackBars; i++)
   {
      double h = iHigh(_Symbol, EntryTimeframe, i);
      double l = iLow(_Symbol, EntryTimeframe, i);
      double c = iClose(_Symbol, EntryTimeframe, i);

      if(bias==1) // Demand zone: B-TRAP = wick below bottom, close back above
      {
         if(l<zoneBottom && c>zoneBottom)
         {
            double pierce = zoneBottom-l;
            confidence = MathMax(confidence, MathMin(100.0, 50.0+MathMin(50.0,(pierce/zoneHeight)*100.0)));
         }
      }
      else // Supply zone: S-TRAP = wick above top, close back below
      {
         if(h>zoneTop && c<zoneTop)
         {
            double pierce = h-zoneTop;
            confidence = MathMax(confidence, MathMin(100.0, 50.0+MathMin(50.0,(pierce/zoneHeight)*100.0)));
         }
      }
   }
   return confidence>0;
}

bool CheckEntryCandlePattern(int bias)
{
   double o1=iOpen(_Symbol,EntryTimeframe,1),  c1=iClose(_Symbol,EntryTimeframe,1);
   double h1=iHigh(_Symbol,EntryTimeframe,1),  l1=iLow(_Symbol,EntryTimeframe,1);
   double o2=iOpen(_Symbol,EntryTimeframe,2),  c2=iClose(_Symbol,EntryTimeframe,2);

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

// Composite Smart Signal score (0-100): Trend alignment (already gated to be
// 100 by construction, since bias itself came from the trend) + Momentum
// (RSI distance from center in the trade's favor) + Zone Confluence (how
// many of the 4 timeframes currently show a same-side zone) + Trap
// confidence from the liquidity-sweep check.
double ComputeSignalScore(int bias, double trapConfidence)
{
   double trendScore = 100.0; // bias already required to match TrendTimeframe

   double rsi[];
   double momentumScore = 0;
   if(CopyBuffer(hRSI_Entry, 0, 1, 1, rsi) >= 1)
   {
      if(bias==1)  momentumScore = MathMax(0.0, MathMin(100.0, (rsi[0]-50.0)*2.0));
      else         momentumScore = MathMax(0.0, MathMin(100.0, (50.0-rsi[0])*2.0));
   }

   int validCount=0;
   for(int i=0;i<ZONE_TF_COUNT;i++)
      if((bias==1 && g_DemandValid[i]) || (bias==-1 && g_SupplyValid[i])) validCount++;
   double zoneScore = MathMin(100.0, validCount*25.0);

   double trapScore = UseTrapFilter ? trapConfidence : 50.0; // neutral contribution if trap filter is off

   return (trendScore+momentumScore+zoneScore+trapScore)/4.0;
}

// Gathers the opposing-side zones that sit ahead of price (targets), nearest
// first, across all 4 timeframes - used to ladder TP1/TP2 (near/far edge of
// the nearest target zone) and TP3 (near edge of the next one after that).
void GetSortedTargetZones(int bias, double curPrice, double &tops[], double &bottoms[], int &count)
{
   count=0;
   double tmpTop[ZONE_TF_COUNT], tmpBot[ZONE_TF_COUNT], tmpDist[ZONE_TF_COUNT];

   for(int i=0;i<ZONE_TF_COUNT;i++)
   {
      bool valid = (bias==1) ? g_SupplyValid[i] : g_DemandValid[i];
      if(!valid) continue;
      double t = (bias==1) ? g_SupplyTop[i] : g_DemandTop[i];
      double b = (bias==1) ? g_SupplyBottom[i] : g_DemandBottom[i];

      bool ahead = (bias==1) ? (b>curPrice) : (t<curPrice);
      if(!ahead) continue;

      double dist = (bias==1) ? (b-curPrice) : (curPrice-t);
      tmpTop[count]=t; tmpBot[count]=b; tmpDist[count]=dist; count++;
   }

   for(int i=1;i<count;i++)
   {
      double dv=tmpDist[i], tv=tmpTop[i], bv=tmpBot[i];
      int j=i-1;
      while(j>=0 && tmpDist[j]>dv) { tmpDist[j+1]=tmpDist[j]; tmpTop[j+1]=tmpTop[j]; tmpBot[j+1]=tmpBot[j]; j--; }
      tmpDist[j+1]=dv; tmpTop[j+1]=tv; tmpBot[j+1]=bv;
   }

   for(int i=0;i<count;i++) { tops[i]=tmpTop[i]; bottoms[i]=tmpBot[i]; }
}

//=========================== TRADE EXECUTION ================================//
void OpenTrade(int bias, double originTop, double originBottom)
{
   double price = (bias==1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (bias==1) ? originBottom-SL_BufferPoints*_Point : originTop+SL_BufferPoints*_Point;

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

   double tops[ZONE_TF_COUNT], bottoms[ZONE_TF_COUNT]; int cnt=0;
   GetSortedTargetZones(bias, price, tops, bottoms, cnt);

   double tp1, tp2, tp3;
   if(bias==1)
   {
      tp1 = (cnt>=1) ? bottoms[0] : price+slDistance*RR_Fallback1;
      tp2 = (cnt>=1) ? tops[0]    : price+slDistance*RR_Fallback2;
      tp3 = (cnt>=2) ? bottoms[1] : price+slDistance*RR_Fallback3;
   }
   else
   {
      tp1 = (cnt>=1) ? tops[0]    : price-slDistance*RR_Fallback1;
      tp2 = (cnt>=1) ? bottoms[0] : price-slDistance*RR_Fallback2;
      tp3 = (cnt>=2) ? tops[1]    : price-slDistance*RR_Fallback3;
   }

   sl = NormalizeDouble(sl, _Digits);
   double tpBroker = NormalizeDouble(tp3, _Digits); // broker-side TP = final target; TP1/TP2 handled as partial closes

   string cmt = (Language==LNG_TH) ? (bias==1?"ZoneAI ซื้อ":"ZoneAI ขาย") : (bias==1?"ZoneAI BUY":"ZoneAI SELL");
   bool ok = (bias==1) ? trade.Buy(lot, _Symbol, price, sl, tpBroker, cmt)
                        : trade.Sell(lot, _Symbol, price, sl, tpBroker, cmt);

   if(ok && PositionSelectForMagic())
   {
      g_EntryTicket = PositionGetInteger(POSITION_TICKET);
      g_TP1Price = tp1; g_TP2Price = tp2; g_TP3Price = tp3;
      g_TP1Done = false; g_TP2Done = false;
   }
}

void ManageOpenPosition()
{
   if(!PositionSelectForMagic())
   {
      if(g_EntryTicket!=0) { g_EntryTicket=0; g_TP1Done=false; g_TP2Done=false; }
      return;
   }

   if(!UsePartialTP) return;

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
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 260);
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

   DashLabel("title", "QUANTIX ZONE AI - MTF SUPPLY/DEMAND", x, y, Dashboard_Yellow, 10); y+=rh+4;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   DashLabel("sym", StringFormat("%s  |  %s: %.2f  |  %s: %d",
             _Symbol, (Language==LNG_TH?"ราคา":"Price"), bid,
             (Language==LNG_TH?"สเปรด":"Spread"), (int)spread),
             x, y, Dashboard_Text); y+=rh;

   string trendTxt = g_TrendBias==1 ? (Language==LNG_TH?"ขาขึ้น":"Bullish")
                     : g_TrendBias==-1 ? (Language==LNG_TH?"ขาลง":"Bearish")
                     : (Language==LNG_TH?"ไม่ชัดเจน":"Flat");
   DashLabel("trend", StringFormat("%s: %s  |  %s: %.0f/100",
             (Language==LNG_TH?"เทรนด์":"Trend"), trendTxt,
             (Language==LNG_TH?"คะแนนล่าสุด":"Last Score"), g_LastScore),
             x, y, g_TrendBias==1?Dashboard_Green:(g_TrendBias==-1?Dashboard_Red:Dashboard_Text)); y+=rh;

   for(int i=0;i<ZONE_TF_COUNT;i++)
   {
      string sTxt = g_SupplyValid[i] ? StringFormat("%.2f-%.2f", g_SupplyBottom[i], g_SupplyTop[i]) : "-";
      string dTxt = g_DemandValid[i] ? StringFormat("%.2f-%.2f", g_DemandBottom[i], g_DemandTop[i]) : "-";
      DashLabel(StringFormat("z%d", i), StringFormat("%s  S:%s  D:%s", g_ZoneTFName[i], sTxt, dTxt), x, y, Dashboard_Text);
      y+=rh;
   }

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
   DashLabel("daypl", StringFormat("%s: %.2f (%.2f%%)  %s: %.2f",
             (Language==LNG_TH?"กำไรวันนี้":"Today P/L"), dayPL, dayPLPct,
             (Language==LNG_TH?"ยอดคงเหลือ":"Equity"), eq),
             x, y, dayPL>=0?Dashboard_Green:Dashboard_Red); y+=rh;

   string statusTxt = ddGuardHalted ? ddGuardReason : (dailyHalted ? haltReason : (Language==LNG_TH?"สถานะ: เทรดได้ปกติ":"Status: Active"));
   DashLabel("status", statusTxt, x, y, (dailyHalted||ddGuardHalted)?Dashboard_Red:Dashboard_Green); y+=rh;
}
//+------------------------------------------------------------------+
