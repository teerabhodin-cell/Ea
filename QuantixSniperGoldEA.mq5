//+------------------------------------------------------------------+
//|                                          QuantixSniperGoldEA.mq5 |
//|   Sniper Precision Entry (Trend + Momentum Pullback + Price      |
//|   Action confluence) for XAUUSD - Single Shot, No Grid/Martingale|
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
input bool   UseSessionFilter       = true;    // London/NY Session Filter (คุมเฉพาะช่วง London/NY)
input int    LondonStartHour        = 8;       // London Start (GMT/UTC)
input int    LondonEndHour          = 17;      // London End
input int    NYStartHour            = 13;      // New York Start (GMT/UTC)
input int    NYEndHour              = 22;      // New York End

input group "===== 2. Sniper Entry - Trend Filter ====="
input int    EMA_Fast_Period        = 21;      // EMA Fast Period
input int    EMA_Slow_Period        = 55;      // EMA Slow Period
input bool   UseMTFTrendFilter      = true;    // Require Higher-TF Trend Agreement (คุมเทรนด์ TF ใหญ่)
input ENUM_TIMEFRAMES MTF_Period    = PERIOD_H1; // MTF Timeframe
input int    MTF_EMA_Period         = 50;      // MTF EMA Period

input group "===== 3. Sniper Entry - Momentum Pullback ====="
input int    RSI_Period             = 14;      // RSI Period
input double RSI_Oversold           = 35.0;    // RSI Oversold Level (โซนขาย)
input double RSI_Overbought         = 65.0;    // RSI Overbought Level (โซนซื้อ)
input double RSI_CenterLine         = 50.0;    // RSI Center Line (เส้นกลาง)
input int    RSI_PullbackLookback   = 5;       // Bars to Look Back for Pullback Touch

input group "===== 4. Sniper Entry - Price Action & Volatility ====="
input bool   UseCandleConfirmation  = true;    // Require Confirming Candle Close (ยืนยันด้วยแท่งเทียน)
input int    ATR_Period             = 14;      // ATR Period
input double ATR_MinPoints          = 150;     // Min ATR, pts (กันตลาดนิ่ง)
input double ATR_MaxPoints          = 4000;    // Max ATR, pts (กันช่วงข่าวแรง)
input int    MaxSpreadPoints        = 350;     // Max Allowed Spread, pts

input group "===== 5. Risk & Money Management ====="
input double RiskPercent            = 0.5;     // Risk % of Equity per Trade
input double SL_ATR_Multiplier      = 1.5;     // Stop Loss = ATR x Multiplier
input double RR_Ratio               = 2.0;     // Take Profit = SL Distance x RR
input double MinLot                 = 0.01;    // Min Lot Cap
input double MaxLot                 = 5.0;     // Max Lot Cap
input int    Slippage               = 20;      // Max Slippage, pts
input ulong  MagicNumber            = 336699;

input group "===== 6. Trade Management ====="
input bool   UseBreakeven           = true;    // Move SL to Breakeven (คุ้มทุน)
input double BreakevenTriggerRR     = 1.0;     // Trigger at Profit = N x Risk (R-Multiple)
input double BreakevenLockPoints    = 20;      // Lock Points Beyond Entry
input bool   UseTrailingStop        = true;    // ATR Trailing Stop (เทรลตาม ATR)
input double TrailingStartRR        = 1.5;     // Start Trailing at Profit = N x Risk
input double TrailingATRMultiplier  = 1.2;     // Trailing Distance = ATR x Multiplier

input group "===== 7. Drawdown Protection ====="
input bool   UseDailyLossLimit      = true;    // Daily Loss Limit (จำกัดขาดทุนรายวัน)
input double MaxDailyLossPercent    = 3.0;     // Max Daily Loss %
input bool   UseTotalDDGuard        = true;    // Total Drawdown Guard (คุม DD สะสม)
input double MaxTotalDDPercent      = 10.0;    // Max Total DD % (from Equity Peak)
input bool   UseEquityLock          = true;    // Equity Floor Lock (ล็อคพอร์ต)
input double MinEquityLimit         = 0.0;     // Min Equity Floor (0 = off)

input group "===== 8. Recovery Mode (Defensive Risk Cut) ====="
input bool   UseRecoveryMode        = true;    // Reduce Risk after Loss Streak (ลดความเสี่ยงหลังแพ้ติด)
input int    RecoveryLossStreak     = 2;       // Consecutive Losses to Trigger
input double RecoveryRiskReduceFactor = 0.5;   // Risk Multiplier while in Recovery
input int    RecoveryCooldownTrades = 3;       // Trades before Auto-Restore (if no win)

input group "===== 9. Dashboard ====="
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
int      hEmaFast = INVALID_HANDLE;
int      hEmaSlow = INVALID_HANDLE;
int      hEmaMTF  = INVALID_HANDLE;
int      hRSI     = INVALID_HANDLE;
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

const string DashPrefix = "QSNP_DASH_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   hEmaFast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEmaMTF  = iMA(_Symbol, MTF_Period,     MTF_EMA_Period,  0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   hATR     = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hEmaMTF==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE)
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
   if(hEmaFast!=INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow!=INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hEmaMTF!=INVALID_HANDLE)  IndicatorRelease(hEmaMTF);
   if(hRSI!=INVALID_HANDLE)     IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE)     IndicatorRelease(hATR);
   ObjectsDeleteAll(0, DashPrefix);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageNewDay();
   CheckDrawdownGuards();
   ManageOpenPosition();

   if(EffectiveShowDashboard()) UpdateDashboard();

   if(!IsNewBar()) return;
   if(tradingHalted) return;
   if(!IsWithinTradingTime()) return;
   if(PositionSelectForMagic()) return; // sniper style: one position at a time
   if(!PassSpreadFilter()) return;
   if(!PassVolatilityFilter()) return;

   int bias = GetTrendBias();
   if(bias==0) return;
   if(!CheckMomentumPullback(bias)) return;
   if(UseCandleConfirmation && !CheckPriceAction(bias)) return;

   OpenSniperTrade(bias);
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

int GetTrendBias()
{
   double emaFast[], emaSlow[];
   if(CopyBuffer(hEmaFast, 0, 1, 1, emaFast) < 1) return 0;
   if(CopyBuffer(hEmaSlow, 0, 1, 1, emaSlow) < 1) return 0;

   int bias = 0;
   if(emaFast[0] > emaSlow[0]) bias = 1;
   else if(emaFast[0] < emaSlow[0]) bias = -1;
   if(bias==0) return 0;

   if(UseMTFTrendFilter)
   {
      double mtfEma[];
      if(CopyBuffer(hEmaMTF, 0, 1, 1, mtfEma) < 1) return 0;
      double mtfClose = iClose(_Symbol, MTF_Period, 1);
      int mtfBias = mtfClose > mtfEma[0] ? 1 : (mtfClose < mtfEma[0] ? -1 : 0);
      if(mtfBias != bias) return 0;
   }

   return bias;
}

bool CheckMomentumPullback(int bias)
{
   int need = RSI_PullbackLookback + 3;
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(hRSI, 0, 0, need, rsi) < need) return false;

   bool crossUp   = (rsi[2] <= RSI_CenterLine && rsi[1] > RSI_CenterLine);
   bool crossDown = (rsi[2] >= RSI_CenterLine && rsi[1] < RSI_CenterLine);

   if(bias==1  && !crossUp)   return false;
   if(bias==-1 && !crossDown) return false;

   bool touched = false;
   for(int i=2; i<2+RSI_PullbackLookback && i<need; i++)
   {
      if(bias==1  && rsi[i] <= RSI_Oversold)   { touched = true; break; }
      if(bias==-1 && rsi[i] >= RSI_Overbought) { touched = true; break; }
   }
   return touched;
}

bool CheckPriceAction(int bias)
{
   double o = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double c = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(bias==1)  return (c > o);
   if(bias==-1) return (c < o);
   return false;
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

   if(lotStep>0) lot = MathFloor(lot/lotStep) * lotStep;
   lot = MathMax(lot, MathMax(MinLot, volMin));
   lot = MathMin(lot, MathMin(MaxLot, volMax));

   return NormalizeDouble(lot, 2);
}

void OpenSniperTrade(int bias)
{
   double atr[];
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return;

   double slDistance = atr[0] * SL_ATR_Multiplier;

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point * 1.1;
   if(slDistance < minDist) slDistance = minDist;

   double lot = CalcLotSize(slDistance);
   if(lot<=0) return;

   double price, sl, tp;
   string cmt;
   bool ok;

   if(bias==1)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl    = NormalizeDouble(price - slDistance, _Digits);
      tp    = NormalizeDouble(price + slDistance*RR_Ratio, _Digits);
      cmt   = (Language==LNG_TH) ? "Sniper ซื้อ" : "Sniper BUY";
      ok    = trade.Buy(lot, _Symbol, price, sl, tp, cmt);
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl    = NormalizeDouble(price + slDistance, _Digits);
      tp    = NormalizeDouble(price - slDistance*RR_Ratio, _Digits);
      cmt   = (Language==LNG_TH) ? "Sniper ขาย" : "Sniper SELL";
      ok    = trade.Sell(lot, _Symbol, price, sl, tp, cmt);
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
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 320);
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

   DashLabel("title", "QUANTIX SNIPER XAUUSD", x, y, Dashboard_Yellow, 10); y+=rh+4;

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

   int bias = GetTrendBias();
   string biasTxt = bias==1 ? (Language==LNG_TH?"ขาขึ้น":"UP")
                   : bias==-1 ? (Language==LNG_TH?"ขาลง":"DOWN")
                   : (Language==LNG_TH?"ไม่ชัดเจน":"FLAT");
   color biasClr = bias==1?Dashboard_Green:(bias==-1?Dashboard_Red:Dashboard_Text);
   DashLabel("bias", StringFormat("%s: %s", (Language==LNG_TH?"เทรนด์":"Trend Bias"), biasTxt),
             x, y, biasClr); y+=rh;

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
      posTxt = (Language==LNG_TH?"สถานะ: รอสัญญาณ Sniper":"Status: Waiting for Sniper Setup");
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
