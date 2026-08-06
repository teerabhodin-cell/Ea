//+------------------------------------------------------------------+
//|                                                QuantixScalpEA.mq5|
//|   Mean-Reversion Scalper: Bollinger Band Bounce + Stochastic     |
//|   Momentum Confirmation, filtered to ranging markets (low ADX)   |
//|   Single Shot per Bar Close, Full Risk Management + Kill Switch  |
//|   Recommended Timeframe: M1 - M5                                 |
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
input bool   UseSessionFilter       = true;    // Only Trade Within Allowed Hours
input bool   UseLocalTime           = false;   // Use Local PC Time (อิงตามเครื่อง, ไม่ใช่ Server)
input int    StartHour              = 7;       // Start Hour
input int    StartMinute            = 0;
input int    EndHour                = 21;      // Stop Hour
input int    EndMinute               = 0;

input group "===== 2. Bollinger Bands (Entry Signal) ====="
input int    BB_Period              = 20;      // BB Period
input double BB_Deviation           = 2.0;     // BB Deviation

input group "===== 3. Stochastic (Momentum Confirmation) ====="
input int    Stoch_K                = 5;       // %K Period
input int    Stoch_D                = 3;       // %D Period
input int    Stoch_Slowing          = 3;       // Slowing
input double Stoch_Oversold         = 20.0;    // Oversold Level
input double Stoch_Overbought       = 80.0;    // Overbought Level

input group "===== 4. Range Filter (Mean Reversion needs Sideway) ====="
input bool   UseRangeFilter         = true;    // Require Ranging Market via ADX (คุมให้เทรดเฉพาะตลาดไม่มีเทรนด์)
input int    ADX_Period             = 14;      // ADX Period
input double ADX_MaxForRanging      = 25.0;    // Max ADX to Allow Entries (สูงกว่านี้ถือว่าเป็นเทรนด์ ไม่ใช่ Range)

input group "===== 5. Filters ====="
input int    MaxSpreadPoints        = 20;      // Max Allowed Spread, pts (สำคัญมากสำหรับ Scalping)
input int    ATR_Period             = 14;      // ATR Period
input double ATR_MinPoints          = 30;      // Min ATR, pts (กันตลาดนิ่งเกินไป)
input double ATR_MaxPoints          = 800;     // Max ATR, pts (กันช่วงข่าวแรง/ผันผวนเกิน)

input group "===== 6. Risk & Money Management ====="
input double RiskPercent            = 0.3;     // Risk % of Equity per Trade
input double SL_BufferPoints        = 15;      // Extra Buffer beyond Band Pierce, pts
input double TP_ATR_FallbackMult    = 1.2;     // TP Fallback = ATR x Mult (if Mid-Band Target Invalid)
input double MinLot                 = 0.01;    // Min Lot Cap
input double MaxLot                 = 5.0;     // Max Lot Cap
input int    Slippage               = 10;      // Max Slippage, pts
input ulong  MagicNumber            = 559911;

input group "===== 7. Trade Management ====="
input bool   UseBreakeven           = true;    // Move SL to Breakeven
input double BreakevenTriggerPoints = 80;      // Breakeven Trigger, pts
input double BreakevenLockPoints    = 5;       // Breakeven Lock, pts
input bool   UseQuickProfitClose    = true;    // Close Early at Small Profit Target (fits scalping)
input double QuickProfitTargetUSD   = 2.0;     // Quick Profit Target, $
input bool   UseTrailingStop        = false;   // Fixed-Points Trailing (optional, usually not needed for scalps)
input double TrailingStartPoints    = 100;     // Trailing Start, pts
input double TrailingDistancePoints = 60;      // Trailing Distance, pts

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
int      hBB    = INVALID_HANDLE;
int      hStoch = INVALID_HANDLE;
int      hADX   = INVALID_HANDLE;
int      hATR   = INVALID_HANDLE;

datetime lastBarTime    = 0;
datetime currentDay     = 0;
double   dayStartEquity = 0;
double   equityPeak     = 0;

bool     dailyHalted    = false;
string   haltReason     = "";
bool     ddGuardHalted  = false;
string   ddGuardReason  = "";

int      g_LastSignal   = 0;

const string DashPrefix = "QSCLP_DASH_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   hBB    = iBands(_Symbol, PERIOD_CURRENT, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   hStoch = iStochastic(_Symbol, PERIOD_CURRENT, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   hADX   = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);
   hATR   = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(hBB==INVALID_HANDLE || hStoch==INVALID_HANDLE || hADX==INVALID_HANDLE || hATR==INVALID_HANDLE)
   {
      Print("QuantixScalpEA: indicator handle creation failed");
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
   if(hBB!=INVALID_HANDLE)    IndicatorRelease(hBB);
   if(hStoch!=INVALID_HANDLE) IndicatorRelease(hStoch);
   if(hADX!=INVALID_HANDLE)   IndicatorRelease(hADX);
   if(hATR!=INVALID_HANDLE)   IndicatorRelease(hATR);
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
   if(!IsNewBar()) return;
   if(!IsWithinSession()) return;
   if(PositionSelectForMagic()) return; // one scalp at a time
   if(!PassSpreadFilter()) return;
   if(!PassVolatilityFilter()) return;
   if(!PassRangeFilter()) return;

   g_LastSignal = EvaluateSignal();
   if(g_LastSignal==0) return;

   OpenScalpTrade(g_LastSignal);
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

bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != lastBarTime) { lastBarTime = t; return true; }
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
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return false;
   double atrPts = atr[0] / _Point;
   return (atrPts >= ATR_MinPoints && atrPts <= ATR_MaxPoints);
}

bool PassRangeFilter()
{
   if(!UseRangeFilter) return true;
   double adx[];
   if(CopyBuffer(hADX, 0, 1, 1, adx) < 1) return false;
   return (adx[0] <= ADX_MaxForRanging);
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

//=========================== SIGNAL ENGINE ================================//
// Buy: last closed candle wicks below the lower band but closes back inside
// (rejection) AND Stochastic crossed up out of oversold on that same closed
// bar. Sell is the mirror image at the upper band / overbought.
int EvaluateSignal()
{
   double bbMid[], bbUp[], bbLow[];
   if(CopyBuffer(hBB, 0, 1, 1, bbMid) < 1) return 0; // base line
   if(CopyBuffer(hBB, 1, 1, 1, bbUp)  < 1) return 0; // upper band
   if(CopyBuffer(hBB, 2, 1, 1, bbLow) < 1) return 0; // lower band

   double stochMain[], stochSignal[];
   ArraySetAsSeries(stochMain, true);
   ArraySetAsSeries(stochSignal, true);
   if(CopyBuffer(hStoch, 0, 0, 3, stochMain)   < 3) return 0;
   if(CopyBuffer(hStoch, 1, 0, 3, stochSignal) < 3) return 0;

   double lowBar1   = iLow(_Symbol, PERIOD_CURRENT, 1);
   double highBar1  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double closeBar1 = iClose(_Symbol, PERIOD_CURRENT, 1);

   bool touchedLower = (lowBar1 <= bbLow[0]) && (closeBar1 > bbLow[0]);
   bool touchedUpper = (highBar1 >= bbUp[0]) && (closeBar1 < bbUp[0]);

   bool stochBullCross = (stochMain[2] <= stochSignal[2]) && (stochMain[1] > stochSignal[1]) && (stochMain[2] <= Stoch_Oversold);
   bool stochBearCross = (stochMain[2] >= stochSignal[2]) && (stochMain[1] < stochSignal[1]) && (stochMain[2] >= Stoch_Overbought);

   if(touchedLower && stochBullCross) return 1;
   if(touchedUpper && stochBearCross) return -1;
   return 0;
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

void OpenScalpTrade(int dir)
{
   double bbMid[];
   if(CopyBuffer(hBB, 0, 1, 1, bbMid) < 1) return;

   double atr[];
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return;

   double price = (dir==1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lowBar1  = iLow(_Symbol, PERIOD_CURRENT, 1);
   double highBar1 = iHigh(_Symbol, PERIOD_CURRENT, 1);

   double sl, tp;
   if(dir==1)
   {
      sl = lowBar1 - SL_BufferPoints*_Point;
      tp = bbMid[0];
      if(tp <= price) tp = price + atr[0]*TP_ATR_FallbackMult; // mid-band too close/invalid - fall back to ATR target
   }
   else
   {
      sl = highBar1 + SL_BufferPoints*_Point;
      tp = bbMid[0];
      if(tp >= price) tp = price - atr[0]*TP_ATR_FallbackMult;
   }

   double slDistance = MathAbs(price-sl);
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point * 1.1;
   if(slDistance < minDist)
   {
      slDistance = minDist;
      sl = (dir==1) ? price-slDistance : price+slDistance;
   }
   if(MathAbs(tp-price) < minDist) tp = (dir==1) ? price+minDist*2 : price-minDist*2;

   double lot = CalcLot(slDistance);
   if(lot<=0) return;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   string cmt = (Language==LNG_TH) ? (dir==1?"Scalp ซื้อ (BB+Stoch)":"Scalp ขาย (BB+Stoch)")
                                     : (dir==1?"Scalp BUY (BB+Stoch)":"Scalp SELL (BB+Stoch)");

   if(dir==1) trade.Buy(lot, _Symbol, price, sl, tp, cmt);
   else       trade.Sell(lot, _Symbol, price, sl, tp, cmt);
}

void ManageOpenPosition()
{
   if(!PositionSelectForMagic()) return;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL     = PositionGetDouble(POSITION_SL);
   double curTP     = PositionGetDouble(POSITION_TP);
   long   type      = PositionGetInteger(POSITION_TYPE);
   double profitUSD = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(UseQuickProfitClose && profitUSD >= QuickProfitTargetUSD)
   {
      trade.PositionClose(_Symbol);
      return;
   }

   if(UseBreakeven)
   {
      double trigDist = BreakevenTriggerPoints*_Point;
      if(type==POSITION_TYPE_BUY && (bid-openPrice)>=trigDist)
      {
         double newSL = openPrice + BreakevenLockPoints*_Point;
         if(curSL<newSL) { trade.PositionModify(_Symbol, NormalizeDouble(newSL,_Digits), curTP); curSL=newSL; }
      }
      else if(type==POSITION_TYPE_SELL && (openPrice-ask)>=trigDist)
      {
         double newSL = openPrice - BreakevenLockPoints*_Point;
         if(curSL==0 || curSL>newSL) { trade.PositionModify(_Symbol, NormalizeDouble(newSL,_Digits), curTP); curSL=newSL; }
      }
   }

   if(UseTrailingStop)
   {
      double trigDist  = TrailingStartPoints*_Point;
      double trailDist = TrailingDistancePoints*_Point;
      if(type==POSITION_TYPE_BUY && (bid-openPrice)>=trigDist)
      {
         double newSL = bid - trailDist;
         if(newSL>curSL) trade.PositionModify(_Symbol, NormalizeDouble(newSL,_Digits), curTP);
      }
      else if(type==POSITION_TYPE_SELL && (openPrice-ask)>=trigDist)
      {
         double newSL = ask + trailDist;
         if(curSL==0 || newSL<curSL) trade.PositionModify(_Symbol, NormalizeDouble(newSL,_Digits), curTP);
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
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 320);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 240);
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

   DashLabel("title", "QUANTIX SCALP EA - BB + STOCH", x, y, Dashboard_Yellow, 10); y+=rh+4;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   DashLabel("sym", StringFormat("%s  |  %s: %.2f  |  %s: %d",
             _Symbol, (Language==LNG_TH?"ราคา":"Price"), bid,
             (Language==LNG_TH?"สเปรด":"Spread"), (int)spread),
             x, y, Dashboard_Text); y+=rh;

   double adx[];
   double adxNow = (CopyBuffer(hADX, 0, 1, 1, adx) >= 1) ? adx[0] : 0;
   bool ranging = adxNow <= ADX_MaxForRanging;
   DashLabel("regime", StringFormat("ADX: %.1f %s", adxNow, ranging?(Language==LNG_TH?"(Range)":"(Ranging)"):(Language==LNG_TH?"(เทรนด์)":"(Trending)")),
             x, y, ranging?Dashboard_Green:Dashboard_Red); y+=rh;

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

   string statusTxt = ddGuardHalted ? ddGuardReason : (dailyHalted ? haltReason : (Language==LNG_TH?"สถานะ: เทรดได้ปกติ":"Status: Active"));
   DashLabel("status", statusTxt, x, y, (dailyHalted||ddGuardHalted)?Dashboard_Red:Dashboard_Green); y+=rh;
}
//+------------------------------------------------------------------+
