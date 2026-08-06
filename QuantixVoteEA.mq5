//+------------------------------------------------------------------+
//|                                                 QuantixVoteEA.mq5|
//|   Majority-Vote Multi-Timeframe EA (2-of-3 Consensus)            |
//|   3 independent signal sources (same logic, 3 timeframes) each   |
//|   vote BUY/SELL/HOLD + Confidence % - trades only when at least  |
//|   2 of 3 agree AND average confidence clears the threshold.      |
//|   Daily Profit/Loss Limit + Session Filter + Concurrent Trade    |
//|   Management (Trailing / Breakeven / Quick Profit Close)         |
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

enum ENUM_LOT_MODE
{
   LOT_FIXED,       // Fixed Lot
   LOT_RISK_PERCENT // Risk % of Equity
};

enum ENUM_SLTP_MODE
{
   SLTP_ATR,          // ATR Multiple
   SLTP_FIXED_POINTS  // Fixed Points
};

//=========================== INPUT ================================//
input group "===== 1. Language & Round Timing ====="
input ENUM_LANGUAGE Language            = LNG_TH;  // Select Language (default: Thai)
input int    AnalysisIntervalSeconds    = 60;      // Analysis Round Interval, sec (ความถี่วิเคราะห์)

input group "===== 2. Daily Limit ====="
input bool   UseDailyProfitTarget       = true;    // Stop When Daily Profit Target Hit
input double DailyProfitTargetPercent   = 3.0;      // Daily Profit Target %
input bool   UseDailyLossLimit          = true;    // Stop When Daily Loss Limit Hit
input double DailyLossLimitPercent      = 3.0;      // Daily Loss Limit %

input group "===== 3. Session Time Filter ====="
input bool   UseSessionFilter           = true;    // Only Trade Within Allowed Hours
input bool   UseLocalTime               = false;   // Use Local PC Time (อิงตามเครื่อง, ไม่ใช่ Server)
input int    StartHour                  = 2;       // Start Hour
input int    StartMinute                = 0;
input int    EndHour                    = 22;      // Stop Hour
input int    EndMinute                  = 0;

input group "===== 4. Voting Sources (3 Timeframes) ====="
input ENUM_TIMEFRAMES VoteTF1           = PERIOD_M15; // Source 1 Timeframe
input ENUM_TIMEFRAMES VoteTF2           = PERIOD_H1;  // Source 2 Timeframe
input ENUM_TIMEFRAMES VoteTF3           = PERIOD_H4;  // Source 3 Timeframe
input int    EMA_Fast_Period            = 21;      // EMA Fast Period (each source)
input int    EMA_Slow_Period            = 55;      // EMA Slow Period (each source)
input int    RSI_Period                 = 14;      // RSI Period (each source)
input int    ATR_Period                 = 14;      // ATR Period (confidence scaling + SL/TP)
input double MinAvgConfidencePercent    = 60.0;    // Min Average Confidence % to Trade

input group "===== 5. Position Sizing ====="
input ENUM_LOT_MODE LotMode             = LOT_RISK_PERCENT; // Lot Sizing Mode
input double FixedLot                   = 0.01;    // Fixed Lot (if LOT_FIXED)
input double RiskPercent                = 0.5;     // Risk % of Equity per Trade (if LOT_RISK_PERCENT)
input double MinLot                     = 0.01;    // Min Lot Cap
input double MaxLot                     = 5.0;     // Max Lot Cap

input group "===== 6. Stop Loss / Take Profit ====="
input ENUM_SLTP_MODE SLTPMode           = SLTP_ATR; // SL/TP Mode
input double ATR_SL_Multiplier          = 1.5;     // SL = ATR x Multiplier (if SLTP_ATR)
input double ATR_TP_Multiplier          = 2.5;     // TP = ATR x Multiplier (if SLTP_ATR)
input int    SL_Points                  = 300;     // Fixed SL, pts (if SLTP_FIXED_POINTS)
input int    TP_Points                  = 600;     // Fixed TP, pts (if SLTP_FIXED_POINTS)
input int    Slippage                   = 20;      // Max Slippage, pts
input ulong  MagicNumber                = 447788;

input group "===== 7. Trade Management (Concurrent Every Tick) ====="
input bool   UseBreakeven               = true;    // Move SL to Breakeven
input double BreakevenTriggerPoints     = 300;     // Breakeven Trigger, pts
input double BreakevenLockPoints        = 20;      // Breakeven Lock, pts
input bool   UseTrailingStop            = true;    // Trailing Stop
input double TrailingStartPoints        = 400;     // Trailing Start, pts
input double TrailingDistancePoints     = 250;     // Trailing Distance, pts
input bool   UseQuickProfitClose        = false;   // Close Early at Small Profit Target
input double QuickProfitTargetUSD       = 5.0;     // Quick Profit Target, $

input group "===== 8. Dashboard ====="
input bool   ShowDashboard              = true;
input bool   ShowDashboardInTester      = false;   // Show Dashboard during Strategy Tester
input int    Dashboard_X                = 15;
input int    Dashboard_Y                = 20;
input color  Dashboard_BG               = C'20,20,20';
input color  Dashboard_Text             = clrWhite;
input color  Dashboard_Green            = clrLimeGreen;
input color  Dashboard_Red              = clrTomato;
input color  Dashboard_Yellow           = clrGold;

//=========================== GLOBALS ================================//
ENUM_TIMEFRAMES g_TF[3];
int      g_hEmaFast[3];
int      g_hEmaSlow[3];
int      g_hRSI[3];
int      g_hATR[3];
int      hATR_Exec = INVALID_HANDLE; // ATR on the chart's own timeframe, used for SL/TP sizing

datetime lastAnalysisTime = 0;
datetime currentDay       = 0;
double   dayStartEquity   = 0;
bool     dailyHalted      = false;
string   haltReason       = "";

int      g_LastVote[3]    = {0,0,0};
double   g_LastConf[3]    = {0,0,0};
bool     g_LastValid[3]   = {false,false,false};
int      g_FinalSignal    = 0;
double   g_AvgConfidence  = 0;

const string DashPrefix = "QVOTE_DASH_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_TF[0] = VoteTF1;
   g_TF[1] = VoteTF2;
   g_TF[2] = VoteTF3;

   for(int i=0; i<3; i++)
   {
      g_hEmaFast[i] = iMA(_Symbol, g_TF[i], EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
      g_hEmaSlow[i] = iMA(_Symbol, g_TF[i], EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
      g_hRSI[i]     = iRSI(_Symbol, g_TF[i], RSI_Period, PRICE_CLOSE);
      g_hATR[i]     = iATR(_Symbol, g_TF[i], ATR_Period);

      if(g_hEmaFast[i]==INVALID_HANDLE || g_hEmaSlow[i]==INVALID_HANDLE ||
         g_hRSI[i]==INVALID_HANDLE || g_hATR[i]==INVALID_HANDLE)
      {
         Print("QuantixVoteEA: indicator handle creation failed for source ", i);
         return INIT_FAILED;
      }
   }

   hATR_Exec = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(hATR_Exec==INVALID_HANDLE)
   {
      Print("QuantixVoteEA: exec ATR handle creation failed");
      return INIT_FAILED;
   }

   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   currentDay     = DayStart(TimeCurrent());

   if(EffectiveShowDashboard()) CreateDashboard();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i=0; i<3; i++)
   {
      if(g_hEmaFast[i]!=INVALID_HANDLE) IndicatorRelease(g_hEmaFast[i]);
      if(g_hEmaSlow[i]!=INVALID_HANDLE) IndicatorRelease(g_hEmaSlow[i]);
      if(g_hRSI[i]!=INVALID_HANDLE)     IndicatorRelease(g_hRSI[i]);
      if(g_hATR[i]!=INVALID_HANDLE)     IndicatorRelease(g_hATR[i]);
   }
   if(hATR_Exec!=INVALID_HANDLE) IndicatorRelease(hATR_Exec);
   ObjectsDeleteAll(0, DashPrefix);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageNewDay();
   ManageOpenPosition();      // trailing / breakeven / quick-profit run every tick, concurrently
   CheckDailyLimits();        // closes everything + halts for the day the moment a target/limit is hit

   if(EffectiveShowDashboard()) UpdateDashboard();

   if(dailyHalted) return;

   if(TimeCurrent() - lastAnalysisTime < AnalysisIntervalSeconds) return;
   lastAnalysisTime = TimeCurrent();

   if(!IsWithinSession()) return;

   RunVotingRound();

   if(g_FinalSignal==0) return;
   if(g_AvgConfidence < MinAvgConfidencePercent) return;

   bool hasPos = PositionSelectForMagic();
   long posType = hasPos ? PositionGetInteger(POSITION_TYPE) : -1;

   if(g_FinalSignal==1)
   {
      if(hasPos && posType==POSITION_TYPE_SELL) CloseAllPositions();
      if(!hasPos || posType==POSITION_TYPE_SELL) OpenPosition(1);
      // if already long, a fresh BUY signal is not stacked - the existing position rides
   }
   else if(g_FinalSignal==-1)
   {
      if(hasPos && posType==POSITION_TYPE_BUY) CloseAllPositions();
      if(!hasPos || posType==POSITION_TYPE_BUY) OpenPosition(-1);
   }
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

void CheckDailyLimits()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPLPct = (dayStartEquity>0) ? (equity-dayStartEquity)/dayStartEquity*100.0 : 0;

   bool hitTarget = UseDailyProfitTarget && dayPLPct >= DailyProfitTargetPercent;
   bool hitLoss   = UseDailyLossLimit    && dayPLPct <= -DailyLossLimitPercent;

   if((hitTarget || hitLoss) && !dailyHalted)
   {
      CloseAllPositions();
      dailyHalted = true;
      if(hitTarget) haltReason = (Language==LNG_TH) ? "ถึงเป้ากำไรวันนี้แล้ว รอรีเซ็ตเที่ยงคืน" : "Daily profit target hit - waiting for midnight reset";
      else          haltReason = (Language==LNG_TH) ? "ถึงจุดขาดทุนวันนี้แล้ว รอรีเซ็ตเที่ยงคืน" : "Daily loss limit hit - waiting for midnight reset";
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

//=========================== VOTING ENGINE ================================//
// One "source" = same EMA-trend + RSI-momentum logic evaluated on its own
// timeframe. Vote: BUY (1) needs EMA fast>slow AND RSI>50; SELL (-1) needs the
// mirror; anything else is HOLD (0). Confidence blends EMA separation
// (relative to that timeframe's ATR) with RSI's distance from the center line.
bool GetSourceVote(int idx, int &voteOut, double &confOut)
{
   double emaFast[], emaSlow[], rsi[], atr[];
   if(CopyBuffer(g_hEmaFast[idx], 0, 1, 1, emaFast) < 1) return false;
   if(CopyBuffer(g_hEmaSlow[idx], 0, 1, 1, emaSlow) < 1) return false;
   if(CopyBuffer(g_hRSI[idx],     0, 1, 1, rsi)     < 1) return false;
   if(CopyBuffer(g_hATR[idx],     0, 1, 1, atr)     < 1) return false;
   if(atr[0] <= 0) return false;

   double emaDiff  = emaFast[0] - emaSlow[0];
   double emaScore = MathMin(100.0, MathAbs(emaDiff)/atr[0]*100.0);
   double rsiScore = MathMin(100.0, MathAbs(rsi[0]-50.0)*2.0);
   confOut = (emaScore + rsiScore) / 2.0;

   voteOut = 0;
   if(emaDiff>0 && rsi[0]>50.0)      voteOut = 1;
   else if(emaDiff<0 && rsi[0]<50.0) voteOut = -1;

   return true;
}

// Aggregates the 3 sources: at least 2/3 must agree on the same non-HOLD
// direction to produce a signal; the confidence used is the average across
// all sources that successfully returned a result (matches the flowchart's
// "average of the sources that answered successfully").
void RunVotingRound()
{
   g_FinalSignal   = 0;
   g_AvgConfidence = 0;

   int validCount = 0;
   double confSum = 0;
   for(int i=0; i<3; i++)
   {
      g_LastValid[i] = GetSourceVote(i, g_LastVote[i], g_LastConf[i]);
      if(g_LastValid[i])
      {
         validCount++;
         confSum += g_LastConf[i];
      }
      else
      {
         g_LastVote[i] = 0;
         g_LastConf[i] = 0;
      }
   }

   if(validCount < 3) return; // any source failing to compute -> skip this round entirely

   g_AvgConfidence = confSum / 3.0;

   int buyCount=0, sellCount=0;
   for(int i=0; i<3; i++)
   {
      if(g_LastVote[i]==1) buyCount++;
      else if(g_LastVote[i]==-1) sellCount++;
   }

   if(buyCount>=2)       g_FinalSignal = 1;
   else if(sellCount>=2) g_FinalSignal = -1;
   else                  g_FinalSignal = 0; // split vote (e.g. 1-1-1) -> HOLD
}

//=========================== TRADE EXECUTION ================================//
bool ComputeSLTP(int direction, double price, double &sl, double &tp)
{
   double slDist, tpDist;

   if(SLTPMode==SLTP_ATR)
   {
      double atr[];
      if(CopyBuffer(hATR_Exec, 0, 1, 1, atr) < 1) return false;
      if(atr[0] <= 0) return false;
      slDist = atr[0]*ATR_SL_Multiplier;
      tpDist = atr[0]*ATR_TP_Multiplier;
   }
   else
   {
      slDist = SL_Points*_Point;
      tpDist = TP_Points*_Point;
   }

   if(slDist<=0 || tpDist<=0) return false;

   sl = (direction==1) ? price-slDist : price+slDist;
   tp = (direction==1) ? price+tpDist : price-tpDist;
   return true;
}

double CalcLot(double slDistance)
{
   double lot;

   if(LotMode==LOT_FIXED)
   {
      lot = FixedLot;
   }
   else
   {
      if(slDistance<=0) return 0;
      double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskMoney = equity * RiskPercent / 100.0;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize<=0 || tickValue<=0) return 0;
      double lossPerLot = (slDistance/tickSize) * tickValue;
      if(lossPerLot<=0) return 0;
      lot = riskMoney / lossPerLot;
   }

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double minLotAllowed = MathMax(MinLot, volMin);

   if(lotStep>0) lot = MathFloor(lot/lotStep) * lotStep;

   if(lot < minLotAllowed)
   {
      // Fixed lot mode: always honor the configured lot (floor to broker min).
      // Risk mode: skip rather than silently over-risking (see CalcLotSize
      // discussion on QuantixSniperGoldEA - same principle applies here).
      if(LotMode==LOT_FIXED) lot = minLotAllowed;
      else return 0;
   }

   lot = MathMin(lot, MathMin(MaxLot, volMax));
   return NormalizeDouble(lot, 2);
}

void OpenPosition(int direction)
{
   double price = (direction==1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double sl, tp;
   if(!ComputeSLTP(direction, price, sl, tp)) return;

   double slDistance = MathAbs(price-sl);
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point * 1.1;
   if(slDistance < minDist)
   {
      slDistance = minDist;
      sl = (direction==1) ? price-slDistance : price+slDistance;
   }

   double lot = CalcLot(slDistance);
   if(lot<=0) return;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   string cmt = (Language==LNG_TH) ? (direction==1?"Vote ซื้อ (2/3)":"Vote ขาย (2/3)")
                                     : (direction==1?"Vote BUY (2/3)":"Vote SELL (2/3)");

   if(direction==1) trade.Buy(lot, _Symbol, price, sl, tp, cmt);
   else              trade.Sell(lot, _Symbol, price, sl, tp, cmt);
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

string VoteLabel(int v)
{
   if(v==1) return "BUY";
   if(v==-1) return "SELL";
   return "HOLD";
}

color VoteColor(int v)
{
   if(v==1) return Dashboard_Green;
   if(v==-1) return Dashboard_Red;
   return Dashboard_Text;
}

void UpdateDashboard()
{
   int x = Dashboard_X;
   int y = Dashboard_Y;
   int rh = 18;

   DashLabel("title", "QUANTIX VOTE EA - 2/3 CONSENSUS", x, y, Dashboard_Yellow, 10); y+=rh+4;

   for(int i=0; i<3; i++)
   {
      string txt = StringFormat("%s [%s]: %s  %.0f%%",
                   (Language==LNG_TH?"แหล่ง":"Src"), EnumToString(g_TF[i]),
                   g_LastValid[i]?VoteLabel(g_LastVote[i]):"N/A", g_LastConf[i]);
      DashLabel(StringFormat("src%d", i), txt, x, y, g_LastValid[i]?VoteColor(g_LastVote[i]):Dashboard_Text);
      y+=rh;
   }

   string finalTxt = StringFormat("%s: %s  (%s %.1f%% / %.1f%%)",
                      (Language==LNG_TH?"สรุป":"Final"), VoteLabel(g_FinalSignal),
                      (Language==LNG_TH?"มั่นใจ":"Conf"), g_AvgConfidence, MinAvgConfidencePercent);
   DashLabel("final", finalTxt, x, y, VoteColor(g_FinalSignal)); y+=rh+4;

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

   string statusTxt = dailyHalted ? haltReason : (Language==LNG_TH?"สถานะ: เทรดได้ปกติ":"Status: Active");
   DashLabel("status", statusTxt, x, y, dailyHalted?Dashboard_Red:Dashboard_Green); y+=rh;
}
//+------------------------------------------------------------------+
