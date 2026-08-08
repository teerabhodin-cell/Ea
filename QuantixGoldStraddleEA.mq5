//+------------------------------------------------------------------+
//|                                        QuantixGoldStraddleEA.mq5 |
//|   XAUUSD M1 Stop & Reverse (SAR):                                |
//|   Always exactly one position open. Its Stop Loss doubles as the |
//|   reversal trigger: a matching opposite Stop order sits at the   |
//|   same price, so when SL is hit the position closes AND a new   |
//|   position opens immediately in the opposite direction. Trailing |
//|   Stop pulls that shared level along as a trade runs in profit,  |
//|   continuously re-arming the next reversal closer to price.      |
//|   Recommended Timeframe: M1 (XAUUSD)                             |
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

enum ENUM_INITIAL_DIRECTION
{
   DIR_AUTO, // ตามทิศทางแท่งเทียนล่าสุด
   DIR_BUY,  // เริ่มด้วย Buy เสมอ
   DIR_SELL  // เริ่มด้วย Sell เสมอ
};

//=========================== INPUT ================================//
input group "===== 1. Language & SAR Setup ====="
input ENUM_LANGUAGE Language            = LNG_TH;  // Select Language (default: Thai)
input ENUM_INITIAL_DIRECTION InitialDirectionMode = DIR_AUTO; // First Position Direction
input double LotSize                    = 0.01;    // Lot per Position
input int    DistancePoints             = 150;     // SL / Reversal Distance, pts (100-200 แนะนำ)
input double PendingTrailStepPoints     = 20;      // Min Move Before Re-Syncing Reverse Order, pts
input ulong  MagicNumber                = 771144;

input group "===== 2. Trailing Stop (also drags the Reversal level) ====="
input bool   UseTrailingStop            = true;    // Trail SL as the Trade Runs in Profit
input double TrailingStartPoints        = 100;     // Trailing Start, pts
input double TrailingDistancePoints     = 50;      // Trailing Distance, pts
input double TrailingStepPoints         = 10;      // Min Move Before Re-Modifying SL, pts

input group "===== 3. Filters (first entry only - reversals always allowed) ====="
input int    MaxSpreadPoints            = 200;     // Max Allowed Spread, pts (สำคัญสำหรับ Gold M1)
input bool   UseSessionFilter           = false;   // Only Open the First Position Within Allowed Hours
input bool   UseLocalTime               = false;   // Use Local PC Time
input int    StartHour                  = 2;       // Start Hour
input int    StartMinute                = 0;
input int    EndHour                    = 22;      // Stop Hour
input int    EndMinute                  = 0;

input group "===== 4. Drawdown Protection (Account-Level Kill Switch) ====="
input bool   UseDailyLossLimit          = true;    // Daily Loss Limit
input double MaxDailyLossPercent        = 5.0;     // Max Daily Loss %
input bool   UseTotalDDGuard            = true;    // Total Drawdown Guard (Kill Switch)
input double MaxTotalDDPercent          = 15.0;    // Max Total DD % (from Equity Peak)
input bool   UseEquityLock              = true;    // Equity Floor Lock
input double MinEquityLimit             = 0.0;     // Min Equity Floor (0 = off)

input group "===== 5. Dashboard ====="
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
ulong    g_ReverseOrderTicket = 0;

datetime currentDay     = 0;
double   dayStartEquity = 0;
double   equityPeak     = 0;

bool     dailyHalted   = false;
string   haltReason    = "";
bool     ddGuardHalted = false;
string   ddGuardReason = "";

int      g_FlipCount = 0;

const string DashPrefix = "QGST_DASH_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   equityPeak     = dayStartEquity;
   currentDay     = DayStart(TimeCurrent());

   if(EffectiveShowDashboard()) CreateDashboard();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, DashPrefix);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageNewDay();
   CheckDailyLimits();
   CheckTotalDDGuard();

   if(EffectiveShowDashboard()) UpdateDashboard();

   if(dailyHalted || ddGuardHalted) return;

   if(PositionSelectForMagic())
   {
      ManageTrailingAndReverseSync();
   }
   else if(!HasPendingOrder())
   {
      if(!IsWithinSession()) return;
      if(!PassSpreadFilter()) return;
      OpenInitialPosition();
   }
   // else: the reverse Stop order is still working, waiting to trigger - nothing to do
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

bool PassSpreadFilter()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= MaxSpreadPoints);
}

double NormalizeLot(double lot)
{
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double l = lot;
   if(lotStep>0) l = MathRound(l/lotStep) * lotStep;
   l = MathMax(l, volMin);
   l = MathMin(l, volMax);
   return NormalizeDouble(l, 2);
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

bool HasPendingOrder()
{
   int total = OrdersTotal();
   for(int i=0; i<total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)MagicNumber) continue;
      return true;
   }
   return false;
}

void CloseAllAndCancelPending()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber) continue;
      trade.PositionClose(ticket);
   }

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=(long)MagicNumber) continue;
      trade.OrderDelete(ticket);
   }

   g_ReverseOrderTicket = 0;
}

//=========================== SAR ENGINE ================================//
void OpenInitialPosition()
{
   int dir;
   if(InitialDirectionMode==DIR_BUY) dir=1;
   else if(InitialDirectionMode==DIR_SELL) dir=-1;
   else
   {
      double o = iOpen(_Symbol, PERIOD_CURRENT, 1);
      double c = iClose(_Symbol, PERIOD_CURRENT, 1);
      dir = (c>=o) ? 1 : -1;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = NormalizeLot(LotSize);
   double price = (dir==1) ? ask : bid;
   double sl = (dir==1) ? price-DistancePoints*_Point : price+DistancePoints*_Point;

   string cmt = (Language==LNG_TH) ? (dir==1?"SAR ซื้อ":"SAR ขาย") : (dir==1?"SAR BUY":"SAR SELL");
   bool ok = (dir==1) ? trade.Buy(lot, _Symbol, price, NormalizeDouble(sl,_Digits), 0, cmt)
                       : trade.Sell(lot, _Symbol, price, NormalizeDouble(sl,_Digits), 0, cmt);

   if(ok) g_FlipCount++;
   // the paired reverse Stop order is placed on the next tick by
   // ManageTrailingAndReverseSync(), once the position is selectable
}

// Every tick: optionally trail the live position's SL in its favor, then make
// sure a reverse Stop order sits exactly at that SL price with the SAME lot
// size - so hitting SL both closes this position AND opens the opposite one.
// The reverse order's own SL is pre-computed and baked in at placement time,
// so the instant it fills, the new position already carries its own
// protective/reversal level with no gap tick.
void ManageTrailingAndReverseSync()
{
   long   type      = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL      = PositionGetDouble(POSITION_SL);
   ulong  posTicket  = PositionGetInteger(POSITION_TICKET);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(UseTrailingStop)
   {
      double trigDist  = TrailingStartPoints*_Point;
      double trailDist = TrailingDistancePoints*_Point;
      double stepDist  = TrailingStepPoints*_Point;
      double newSL = curSL;

      if(type==POSITION_TYPE_BUY && (bid-openPrice)>=trigDist)
      {
         double candidate = bid-trailDist;
         if(curSL==0 || candidate>curSL+stepDist) newSL = candidate;
      }
      else if(type==POSITION_TYPE_SELL && (openPrice-ask)>=trigDist)
      {
         double candidate = ask+trailDist;
         if(curSL==0 || candidate<curSL-stepDist) newSL = candidate;
      }

      if(newSL!=curSL)
      {
         trade.PositionModify(posTicket, NormalizeDouble(newSL,_Digits), 0);
         curSL = newSL;
      }
   }

   SyncReverseOrder(type, curSL);
}

void SyncReverseOrder(long currentType, double slPrice)
{
   if(slPrice<=0) return; // no level to reverse at yet

   double lot = NormalizeLot(LotSize);
   // The reverse order's own future SL, baked in now so the flipped position
   // is protected the instant it fills (one DistancePoints step further on).
   double nextSL = (currentType==POSITION_TYPE_BUY) ? slPrice+DistancePoints*_Point
                                                       : slPrice-DistancePoints*_Point;

   if(g_ReverseOrderTicket!=0 && OrderSelect(g_ReverseOrderTicket))
   {
      double curPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(slPrice-curPrice) >= PendingTrailStepPoints*_Point)
      {
         trade.OrderModify(g_ReverseOrderTicket, NormalizeDouble(slPrice,_Digits),
                            NormalizeDouble(nextSL,_Digits), 0, ORDER_TIME_GTC, 0);
      }
      return;
   }

   // No live reverse order (first time, or the previous one just triggered) - place a fresh one
   string cmt = (Language==LNG_TH) ? "SAR Reverse" : "SAR Reverse";
   bool ok;
   if(currentType==POSITION_TYPE_BUY)
      ok = trade.SellStop(lot, NormalizeDouble(slPrice,_Digits), _Symbol,
                           NormalizeDouble(nextSL,_Digits), 0, ORDER_TIME_GTC, 0, cmt);
   else
      ok = trade.BuyStop(lot, NormalizeDouble(slPrice,_Digits), _Symbol,
                          NormalizeDouble(nextSL,_Digits), 0, ORDER_TIME_GTC, 0, cmt);

   if(ok) g_ReverseOrderTicket = trade.ResultOrder();
}

void CheckDailyLimits()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPLPct = (dayStartEquity>0) ? (equity-dayStartEquity)/dayStartEquity*100.0 : 0;

   bool hitLoss = UseDailyLossLimit && dayPLPct <= -MaxDailyLossPercent;
   if(hitLoss && !dailyHalted)
   {
      CloseAllAndCancelPending();
      dailyHalted = true;
      haltReason = (Language==LNG_TH) ? "หยุดเทรด: ขาดทุนรายวันเกินกำหนด รอรีเซ็ตเที่ยงคืน" : "Halted: Daily loss limit hit - waiting for midnight reset";
   }

   if(!dailyHalted && UseEquityLock && MinEquityLimit>0 && equity<=MinEquityLimit)
   {
      CloseAllAndCancelPending();
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
      CloseAllAndCancelPending();
      ddGuardHalted = true;
      ddGuardReason = (Language==LNG_TH)
                      ? StringFormat("หยุดเทรดถาวร: DD รวม %.1f%% เกินกำหนด (Peak %.2f)", ddPct, equityPeak)
                      : StringFormat("Halted permanently: Total DD %.1f%% exceeded (Peak %.2f)", ddPct, equityPeak);
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
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 330);
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

   DashLabel("title", "QUANTIX GOLD SAR - M1", x, y, Dashboard_Yellow, 10); y+=rh+4;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   DashLabel("sym", StringFormat("%s  |  %s: %.2f  |  %s: %d",
             _Symbol, (Language==LNG_TH?"ราคา":"Price"), bid,
             (Language==LNG_TH?"สเปรด":"Spread"), (int)spread),
             x, y, Dashboard_Text); y+=rh;

   DashLabel("flips", StringFormat("%s: %d", (Language==LNG_TH?"จำนวนครั้งที่กลับทิศ":"Reversals"), g_FlipCount),
             x, y, Dashboard_Text); y+=rh;

   bool hasPos = PositionSelectForMagic();
   string posTxt; color posClr = Dashboard_Text;
   double curSL = 0;
   if(hasPos)
   {
      long type = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT);
      curSL = PositionGetDouble(POSITION_SL);
      posTxt = StringFormat("%s %s %.2f | P/L %.2f | SL %.2f",
               (Language==LNG_TH?"ทิศทาง":"Direction"),
               type==POSITION_TYPE_BUY?"BUY":"SELL", vol, profit, curSL);
      posClr = profit>=0?Dashboard_Green:Dashboard_Red;
   }
   else
   {
      posTxt = (Language==LNG_TH?"ไม่มีออเดอร์เปิดอยู่":"No Open Position");
   }
   DashLabel("pos", posTxt, x, y, posClr); y+=rh;

   string revTxt = (g_ReverseOrderTicket!=0 && OrderSelect(g_ReverseOrderTicket))
                   ? StringFormat("%s: %.2f", (Language==LNG_TH?"จุดกลับทิศถัดไป":"Next Reverse Level"), OrderGetDouble(ORDER_PRICE_OPEN))
                   : (Language==LNG_TH?"ยังไม่มีจุดกลับทิศ":"No reverse order yet");
   DashLabel("reverse", revTxt, x, y, Dashboard_Yellow); y+=rh;

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

   string statusTxt = ddGuardHalted ? ddGuardReason : (dailyHalted ? haltReason : (Language==LNG_TH?"สถานะ: เทรดได้ปกติ":"Status: Active"));
   DashLabel("status", statusTxt, x, y, (dailyHalted||ddGuardHalted)?Dashboard_Red:Dashboard_Green); y+=rh;
}
//+------------------------------------------------------------------+
