//+------------------------------------------------------------------+
//|                                        QuantixGoldStraddleEA.mq5 |
//|   XAUUSD M1 Dual Buy/Sell Straddle Scalper:                      |
//|   Opens Buy+Sell together (market or Buy Stop/Sell Stop pending) |
//|   Trailing Stop on the winning leg, Trailing Pending on the      |
//|   untriggered leg (keeps a constant Distance Step from price)    |
//|   Closes the whole basket at a net profit target (or max loss    |
//|   safety net), then immediately opens a fresh cycle              |
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

enum ENUM_ENTRY_MODE
{
   ENTRY_PENDING_STRADDLE, // Buy Stop / Sell Stop คร่อมราคา
   ENTRY_MARKET_DUAL       // เปิด Buy + Sell พร้อมกันที่ตลาด
};

//=========================== INPUT ================================//
input group "===== 1. Language & Cycle Setup ====="
input ENUM_LANGUAGE Language        = LNG_TH;  // Select Language (default: Thai)
input ENUM_ENTRY_MODE EntryMode     = ENTRY_PENDING_STRADDLE; // Initial Entry Mode
input double LotSize                = 0.01;    // Lot per Side (Buy กับ Sell เท่ากัน)
input int    DistancePoints         = 150;     // Straddle Distance from Price, pts (100-200 แนะนำ)
input ulong  MagicNumber            = 771144;

input group "===== 2. Trailing Stop (Winning Leg) ====="
input bool   UseTrailingStop        = true;    // Trail SL on the Profitable Side
input double TrailingStartPoints    = 100;     // Trailing Start, pts
input double TrailingDistancePoints = 50;      // Trailing Distance, pts
input double TrailingStepPoints     = 10;      // Min Move Before Re-Modifying SL, pts

input group "===== 3. Trailing Pending (Untriggered Leg) ====="
input bool   UseTrailingPending     = true;    // Chase Untriggered Pending Order (Pending Mode only)
input double PendingTrailStepPoints = 30;      // Min Price Move Before Re-Centering Pending, pts

input group "===== 4. Basket Management ====="
input double TargetProfitUSD        = 20.0;    // Close Whole Basket at Net Profit, $ (10-30 แนะนำ)
input bool   UseBasketMaxLoss       = true;    // Safety Net: Close Basket if Loss Exceeds Limit
input double BasketMaxLossUSD       = 50.0;    // Max Basket Floating Loss, $ (ตัดขาดทุนฉุกเฉิน)
input double EmergencySLPoints      = 300;     // Hard SL per Leg on Fill, pts (0 = off, กันไม้เปล่า SL ก่อนถึง Trailing)

input group "===== 5. Filters ====="
input int    MaxSpreadPoints        = 200;     // Max Allowed Spread, pts (สำคัญสำหรับ Gold M1)
input bool   UseSessionFilter       = false;   // Only Open New Cycles Within Allowed Hours
input bool   UseLocalTime           = false;   // Use Local PC Time
input int    StartHour              = 2;       // Start Hour
input int    StartMinute            = 0;
input int    EndHour                = 22;      // Stop Hour
input int    EndMinute              = 0;

input group "===== 6. Drawdown Protection (Account-Level Kill Switch) ====="
input bool   UseDailyLossLimit      = true;    // Daily Loss Limit
input double MaxDailyLossPercent    = 5.0;     // Max Daily Loss %
input bool   UseTotalDDGuard        = true;    // Total Drawdown Guard (Kill Switch)
input double MaxTotalDDPercent      = 15.0;    // Max Total DD % (from Equity Peak)
input bool   UseEquityLock          = true;    // Equity Floor Lock
input double MinEquityLimit         = 0.0;     // Min Equity Floor (0 = off)

input group "===== 7. Dashboard ====="
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
ulong    g_BuyStopTicket  = 0;
ulong    g_SellStopTicket = 0;

datetime currentDay     = 0;
double   dayStartEquity = 0;
double   equityPeak     = 0;

bool     dailyHalted   = false;
string   haltReason    = "";
bool     ddGuardHalted = false;
string   ddGuardReason = "";

int      g_CycleCount = 0;

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

   ManageTrailingStop();
   ManageTrailingPending();
   CheckBasketTargets();

   if(!HasAnyOpenOrPending())
   {
      if(!IsWithinSession()) return;
      if(!PassSpreadFilter()) return;
      StartNewCycle();
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

bool HasAnyOpenOrPending()
{
   int totalPos = PositionsTotal();
   for(int i=0; i<totalPos; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber) continue;
      return true;
   }

   int totalOrd = OrdersTotal();
   for(int i=0; i<totalOrd; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=(long)MagicNumber) continue;
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

   g_BuyStopTicket  = 0;
   g_SellStopTicket = 0;
}

//=========================== CYCLE / ENTRY ================================//
void StartNewCycle()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = NormalizeLot(LotSize);
   double slBuf = EmergencySLPoints*_Point;

   if(EntryMode==ENTRY_MARKET_DUAL)
   {
      string cmtB = (Language==LNG_TH) ? "Straddle ซื้อ" : "Straddle BUY";
      string cmtS = (Language==LNG_TH) ? "Straddle ขาย" : "Straddle SELL";

      double slBuy  = (EmergencySLPoints>0) ? NormalizeDouble(ask-slBuf,_Digits) : 0;
      double slSell = (EmergencySLPoints>0) ? NormalizeDouble(bid+slBuf,_Digits) : 0;

      trade.Buy(lot, _Symbol, ask, slBuy, 0, cmtB);
      trade.Sell(lot, _Symbol, bid, slSell, 0, cmtS);
   }
   else // ENTRY_PENDING_STRADDLE
   {
      double buyStopPrice  = NormalizeDouble(ask + DistancePoints*_Point, _Digits);
      double sellStopPrice = NormalizeDouble(bid - DistancePoints*_Point, _Digits);

      double slBuy  = (EmergencySLPoints>0) ? NormalizeDouble(buyStopPrice-slBuf,_Digits)  : 0;
      double slSell = (EmergencySLPoints>0) ? NormalizeDouble(sellStopPrice+slBuf,_Digits) : 0;

      string cmtB = (Language==LNG_TH) ? "Straddle BuyStop" : "Straddle BuyStop";
      string cmtS = (Language==LNG_TH) ? "Straddle SellStop" : "Straddle SellStop";

      if(trade.BuyStop(lot, buyStopPrice, _Symbol, slBuy, 0, ORDER_TIME_GTC, 0, cmtB))
         g_BuyStopTicket = trade.ResultOrder();

      if(trade.SellStop(lot, sellStopPrice, _Symbol, slSell, 0, ORDER_TIME_GTC, 0, cmtS))
         g_SellStopTicket = trade.ResultOrder();
   }

   g_CycleCount++;
}

// Ratchets SL on whichever leg(s) are in profit - never loosens, only tightens
// in the position's favor. Applies to both legs independently since in
// pending mode both can end up live (hedged) at the same time.
void ManageTrailingStop()
{
   if(!UseTrailingStop) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double trigDist  = TrailingStartPoints*_Point;
   double trailDist = TrailingDistancePoints*_Point;
   double stepDist  = TrailingStepPoints*_Point;

   int total = PositionsTotal();
   for(int i=0; i<total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber) continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL      = PositionGetDouble(POSITION_SL);
      double curTP      = PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY && (bid-openPrice)>=trigDist)
      {
         double newSL = bid - trailDist;
         if(curSL==0 || newSL > curSL+stepDist)
            trade.PositionModify(ticket, NormalizeDouble(newSL,_Digits), curTP);
      }
      else if(type==POSITION_TYPE_SELL && (openPrice-ask)>=trigDist)
      {
         double newSL = ask + trailDist;
         if(curSL==0 || newSL < curSL-stepDist)
            trade.PositionModify(ticket, NormalizeDouble(newSL,_Digits), curTP);
      }
   }
}

// Re-centers whichever pending order(s) are still untriggered so they keep a
// constant Distance Step from the current market price instead of getting
// left behind (or too close) as price runs. Only relevant in pending mode -
// the other, already-filled leg is handled by ManageTrailingStop() instead.
void ManageTrailingPending()
{
   if(EntryMode!=ENTRY_PENDING_STRADDLE || !UseTrailingPending) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = DistancePoints*_Point;
   double stepDist = PendingTrailStepPoints*_Point;

   if(g_BuyStopTicket!=0 && OrderSelect(g_BuyStopTicket))
   {
      double curPrice   = OrderGetDouble(ORDER_PRICE_OPEN);
      double curSL      = OrderGetDouble(ORDER_SL);
      double curTP      = OrderGetDouble(ORDER_TP);
      double idealPrice = ask + gap;
      if(MathAbs(idealPrice-curPrice) >= stepDist)
      {
         double newSL = (curSL!=0) ? NormalizeDouble(idealPrice-EmergencySLPoints*_Point,_Digits) : 0;
         trade.OrderModify(g_BuyStopTicket, NormalizeDouble(idealPrice,_Digits), newSL, curTP, ORDER_TIME_GTC, 0);
      }
   }

   if(g_SellStopTicket!=0 && OrderSelect(g_SellStopTicket))
   {
      double curPrice   = OrderGetDouble(ORDER_PRICE_OPEN);
      double curSL      = OrderGetDouble(ORDER_SL);
      double curTP      = OrderGetDouble(ORDER_TP);
      double idealPrice = bid - gap;
      if(MathAbs(idealPrice-curPrice) >= stepDist)
      {
         double newSL = (curSL!=0) ? NormalizeDouble(idealPrice+EmergencySLPoints*_Point,_Digits) : 0;
         trade.OrderModify(g_SellStopTicket, NormalizeDouble(idealPrice,_Digits), newSL, curTP, ORDER_TIME_GTC, 0);
      }
   }
}

// Net Basket P/L = sum of every open leg's floating profit + swap. Closes
// everything (positions and any still-pending order) the moment the target
// is reached, or the safety-net max loss is breached, then immediately opens
// a fresh cycle at the current price (subject to session/spread filters).
void CheckBasketTargets()
{
   double totalProfit = 0;
   bool anyPosition = false;

   int total = PositionsTotal();
   for(int i=0; i<total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber) continue;
      totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      anyPosition = true;
   }

   if(!anyPosition) return;

   bool hitTarget = totalProfit >= TargetProfitUSD;
   bool hitMaxLoss = UseBasketMaxLoss && totalProfit <= -BasketMaxLossUSD;

   if(hitTarget || hitMaxLoss)
   {
      CloseAllAndCancelPending();
      if(!dailyHalted && !ddGuardHalted && IsWithinSession() && PassSpreadFilter())
         StartNewCycle();
   }
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

   DashLabel("title", "QUANTIX GOLD STRADDLE - M1", x, y, Dashboard_Yellow, 10); y+=rh+4;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   DashLabel("sym", StringFormat("%s  |  %s: %.2f  |  %s: %d",
             _Symbol, (Language==LNG_TH?"ราคา":"Price"), bid,
             (Language==LNG_TH?"สเปรด":"Spread"), (int)spread),
             x, y, Dashboard_Text); y+=rh;

   DashLabel("cycle", StringFormat("%s: %d  |  %s: %s",
             (Language==LNG_TH?"รอบที่":"Cycle"), g_CycleCount,
             (Language==LNG_TH?"โหมด":"Mode"),
             EntryMode==ENTRY_MARKET_DUAL?(Language==LNG_TH?"ตลาดคู่":"Market Dual"):(Language==LNG_TH?"Pending คร่อม":"Pending Straddle")),
             x, y, Dashboard_Text); y+=rh;

   double totalProfit=0; string buyTxt="-", sellTxt="-";
   color buyClr=Dashboard_Text, sellClr=Dashboard_Text;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      totalProfit+=profit;
      if(type==POSITION_TYPE_BUY)  { buyTxt=StringFormat("BUY %.2f | %.2f",vol,profit);  buyClr=profit>=0?Dashboard_Green:Dashboard_Red; }
      else                         { sellTxt=StringFormat("SELL %.2f | %.2f",vol,profit); sellClr=profit>=0?Dashboard_Green:Dashboard_Red; }
   }
   DashLabel("buy", (Language==LNG_TH?"ฝั่งซื้อ: ":"Buy Leg: ")+buyTxt, x, y, buyClr); y+=rh;
   DashLabel("sell", (Language==LNG_TH?"ฝั่งขาย: ":"Sell Leg: ")+sellTxt, x, y, sellClr); y+=rh;

   DashLabel("basket", StringFormat("%s: %.2f / %.2f", (Language==LNG_TH?"รวมพอร์ต/เป้า":"Basket/Target"), totalProfit, TargetProfitUSD),
             x, y, totalProfit>=0?Dashboard_Green:Dashboard_Red); y+=rh;

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
