//+------------------------------------------------------------------+
//|                                                 QuantixFlowEA.mq5 |
//|        Tick-Microstructure Scalper (LightGBM via ONNX)           |
//+------------------------------------------------------------------+
// XAUUSD does not expose real trade-side (aggressor buy/sell) or genuine
// traded volume through MT5's MqlTick on almost any retail CFD broker, and
// MarketBookGet() depth-of-book data cannot be backtested in the Strategy
// Tester at all. So this EA does NOT attempt real order-flow/CVD - instead
// it derives tick-microstructure features from Bid/Ask/Time alone (tick
// velocity, price velocity/acceleration, spread z-score, tick direction
// ratio, micro volatility), which are fully backtestable since they only
// need ordinary tick history.
#include <Trade\Trade.mqh>
CTrade trade;

enum ENUM_LANGUAGE
{
   LNG_TH, // ภาษาไทย (Thai)
   LNG_EN  // English
};

input group "===== 1. Language ====="
input ENUM_LANGUAGE Language        = LNG_TH;

input group "===== 2. Feature Window ====="
input int    WindowSize             = 30;     // Rolling window, ticks
input int    AccelLookback          = 5;      // Ticks back for price_acceleration

input group "===== 3. AI Model (ONNX / LightGBM) ====="
input bool   UseAIModel             = false;   // Off until a model is trained - see train_flow_model.py. No model = no trades (fails closed, unlike QuantixApexEA's optional gate, because this EA has no rule-based fallback signal at all)
input string AIModelFileName        = "QuantixFlowEA_model.onnx"; // File in Common\Files
input double MinBuyProbability      = 0.80;    // Min P(up) to open BUY
input double MinSellProbability     = 0.80;    // Min P(down) to open SELL

input group "===== 4. Execution Filters ====="
input int    MaxSpreadPoints        = 250;     // Max Allowed Spread, pts
input bool   UseSessionFilter       = true;    // Only Trade Within Allowed Hours
input int    StartHour              = 2;
input int    EndHour                = 22;

input group "===== 5. Trade Management ====="
input double SL_Points              = 50;      // Stop Loss, points (tight - this is a scalper, not a swing system)
input double TP_Points              = 100;     // Take Profit, points
input double RiskPercent            = 0.5;     // Risk % of Equity per Trade (kept small - high trade frequency compounds risk fast)
input double MinLot                 = 0.01;
input double MaxLot                 = 5.0;
input bool   AllowMinLotOverride    = true;    // Open at MinLot instead of skipping when risk-sized lot rounds below it (see QuantixApexEA - same reasoning)
input int    Slippage               = 20;      // Max Slippage, pts
input ulong  MagicNumber            = 990211;

input group "===== 6. Drawdown Protection (Kill Switch) ====="
input bool   UseDailyLossLimit      = true;
input double MaxDailyLossPercent    = 3.0;
input bool   UseTotalDDGuard        = true;
input double MaxTotalDDPercent      = 10.0;
input bool   UseEquityLock          = true;
input double MinEquityLimit         = 0.0;     // 0 = off

input group "===== 7. Training Data Logger ====="
input bool   UseTrainingLogger      = true;    // Logs a feature snapshot + realized forward move every sampled tick, independent of any trade decision - this is how you bootstrap data to train the first model (there's no rule-based signal here to log setup/outcome from, unlike QuantixApexEA)
input string TrainingLogFileName    = "QuantixFlowEA_TrainingLog.csv"; // File in Common\Files
input int    LabelLookaheadTicks    = 30;      // Ticks ahead to measure the forward price move that becomes the label
input int    LogSampleEveryNTicks   = 3;       // Log 1 out of every N ticks (controls file growth rate)

input group "===== 8. Dashboard ====="
input bool   ShowDashboard          = true;
input bool   ShowDashboardInTester  = false;
input int    Dashboard_X            = 15;
input int    Dashboard_Y            = 20;

//=========================== GLOBALS ================================//
long   g_OnnxHandle = INVALID_HANDLE;
int    g_TrainingLogHandle = INVALID_HANDLE;

int    g_BufferSize;
double g_midBuf[];
double g_spreadBuf[];
double g_timeSecBuf[];
int    g_bufHead  = -1;
int    g_bufCount = 0;

int    g_VelBufSize;
double g_velBuf[];       // history of price_velocity, for acceleration
int    g_velHead  = -1;
int    g_velCount = 0;

struct PendingLog
{
   double refMid;
   double tick_velocity;
   double price_velocity;
   double price_acceleration;
   double spread_zscore;
   double tick_direction_ratio;
   double micro_volatility;
   int    age;
};
PendingLog g_pending[];
int        g_pendingCount = 0;

long g_tickCounter = 0;

datetime g_currentDay     = 0;
double   g_dayStartEquity = 0;
double   g_equityPeak     = 0;
bool     g_dailyHalted    = false;
string   g_haltReason     = "";
bool     g_ddGuardHalted  = false;
string   g_ddGuardReason  = "";

double g_lastProbBuy  = -1;
double g_lastProbSell = -1;

const string DashPrefix = "QFLOW_DASH_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(WindowSize < 2 || AccelLookback < 1)
   {
      Print("QuantixFlowEA: WindowSize/AccelLookback too small");
      return INIT_FAILED;
   }

   g_BufferSize = WindowSize + AccelLookback + 10;
   ArrayResize(g_midBuf, g_BufferSize);
   ArrayResize(g_spreadBuf, g_BufferSize);
   ArrayResize(g_timeSecBuf, g_BufferSize);

   g_VelBufSize = AccelLookback + 5;
   ArrayResize(g_velBuf, g_VelBufSize);

   ArrayResize(g_pending, 500);
   g_pendingCount = 0;

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_equityPeak      = g_dayStartEquity;
   g_currentDay       = DayStart(TimeCurrent());

   if(EffectiveShowDashboard()) CreateDashboard();

   if(UseTrainingLogger)
   {
      // Opened once and kept open for the EA's lifetime - this file used to be
      // FileOpen()'d and FileClose()'d on every single maturing log row (every
      // ~LogSampleEveryNTicks ticks, for the entire backtest), which is disk
      // I/O on every tick and was the main reason the tester ran so slowly.
      g_TrainingLogHandle = OpenTrainingLogFile();
      if(g_TrainingLogHandle == INVALID_HANDLE)
         Print("QuantixFlowEA: training log disabled for this run (failed to open)");
      else
         Print("QuantixFlowEA: training log -> ", TerminalInfoString(TERMINAL_COMMONDATA_PATH), "\\Files\\", TrainingLogFileName);
   }

   if(UseAIModel)
   {
      g_OnnxHandle = OnnxCreate(AIModelFileName, ONNX_COMMON_FOLDER);
      if(g_OnnxHandle == INVALID_HANDLE)
      {
         Print("QuantixFlowEA: failed to load AI model '", AIModelFileName,
               "' from Common\\Files, err=", GetLastError(), " - no model means no entries at all (fail-closed)");
      }
      else
      {
         ulong inputShape[] = {1, 6};
         ulong labelShape[] = {1};
         ulong probShape[]  = {1, 3};
         bool ok = OnnxSetInputShape(g_OnnxHandle, 0, inputShape)
                && OnnxSetOutputShape(g_OnnxHandle, 0, labelShape)
                && OnnxSetOutputShape(g_OnnxHandle, 1, probShape);
         if(!ok)
         {
            Print("QuantixFlowEA: OnnxSetInputShape/OutputShape failed, err=", GetLastError());
            OnnxRelease(g_OnnxHandle);
            g_OnnxHandle = INVALID_HANDLE;
         }
         else
            Print("QuantixFlowEA: AI model loaded -> ", AIModelFileName);
      }
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_OnnxHandle != INVALID_HANDLE) OnnxRelease(g_OnnxHandle);
   if(g_TrainingLogHandle != INVALID_HANDLE) FileClose(g_TrainingLogHandle);
   ObjectsDeleteAll(0, DashPrefix);
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

bool PositionSelectForMagic()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==(long)MagicNumber)
         return true;
   }
   return false;
}

bool IsWithinSession()
{
   if(!UseSessionFilter) return true;
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   int curMin   = tm.hour*60 + tm.min;
   int startMin = StartHour*60;
   int endMin   = EndHour*60;
   if(startMin <= endMin) return (curMin>=startMin && curMin<endMin);
   return (curMin>=startMin || curMin<endMin);
}

//=========================== DAILY / DD GUARD ================================//
void ManageNewDay()
{
   datetime today = DayStart(TimeCurrent());
   if(today != g_currentDay)
   {
      g_currentDay      = today;
      g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dailyHalted     = false;
      g_haltReason      = "";
   }
   if(UseDailyLossLimit && !g_dailyHalted)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double lossPct = (g_dayStartEquity>0) ? (g_dayStartEquity-equity)/g_dayStartEquity*100.0 : 0;
      if(lossPct >= MaxDailyLossPercent)
      {
         g_dailyHalted = true;
         g_haltReason  = StringFormat("Daily loss %.2f%% >= limit %.2f%%", lossPct, MaxDailyLossPercent);
      }
   }
}

void CheckTotalDDGuard()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_equityPeak) g_equityPeak = equity;

   if(UseTotalDDGuard && !g_ddGuardHalted)
   {
      double ddPct = (g_equityPeak>0) ? (g_equityPeak-equity)/g_equityPeak*100.0 : 0;
      if(ddPct >= MaxTotalDDPercent)
      {
         g_ddGuardHalted = true;
         g_ddGuardReason = StringFormat("Total DD %.2f%% >= limit %.2f%% (peak %.2f)", ddPct, MaxTotalDDPercent, g_equityPeak);
         if(PositionSelectForMagic()) trade.PositionClose((ulong)PositionGetInteger(POSITION_TICKET));
      }
   }
   if(UseEquityLock && MinEquityLimit>0 && !g_ddGuardHalted && equity<=MinEquityLimit)
   {
      g_ddGuardHalted = true;
      g_ddGuardReason = StringFormat("Equity floor %.2f hit (equity %.2f)", MinEquityLimit, equity);
      if(PositionSelectForMagic()) trade.PositionClose((ulong)PositionGetInteger(POSITION_TICKET));
   }
}

//=========================== RING BUFFER ================================//
void PushTick(double mid, double spread, double timeSec)
{
   g_bufHead = (g_bufHead+1) % g_BufferSize;
   g_midBuf[g_bufHead]    = mid;
   g_spreadBuf[g_bufHead] = spread;
   g_timeSecBuf[g_bufHead]= timeSec;
   if(g_bufCount < g_BufferSize) g_bufCount++;
}

// value `offset` ticks ago (0 = current/most recent). +g_BufferSize*2 keeps
// the operand non-negative before the modulo, since MQL5's % on a negative
// left-hand side does not behave like a true mathematical modulo.
double BufMid(int offset)     { int idx=(g_bufHead-offset+g_BufferSize*2)%g_BufferSize; return g_midBuf[idx]; }
double BufSpread(int offset)  { int idx=(g_bufHead-offset+g_BufferSize*2)%g_BufferSize; return g_spreadBuf[idx]; }
double BufTimeSec(int offset) { int idx=(g_bufHead-offset+g_BufferSize*2)%g_BufferSize; return g_timeSecBuf[idx]; }

void PushVel(double v)
{
   g_velHead = (g_velHead+1) % g_VelBufSize;
   g_velBuf[g_velHead] = v;
   if(g_velCount < g_VelBufSize) g_velCount++;
}
double VelAgo(int offset) { int idx=(g_velHead-offset+g_VelBufSize*2)%g_VelBufSize; return g_velBuf[idx]; }

//=========================== FEATURE ENGINEERING ================================//
// Mirrors extract_mt5_micro_features() in train_flow_model.py exactly -
// keep both in sync if you change either one.
bool ComputeFeatures(double &tick_velocity, double &price_velocity, double &price_acceleration,
                      double &spread_zscore, double &tick_direction_ratio, double &micro_volatility,
                      double &midNow, double &spreadNow)
{
   if(g_bufCount < WindowSize+1) return false;

   midNow    = BufMid(0);
   spreadNow = BufSpread(0);
   double timeNow = BufTimeSec(0);

   double midAgo  = BufMid(WindowSize);
   double timeAgo = BufTimeSec(WindowSize);
   double dt = timeNow - timeAgo;

   tick_velocity  = (dt>0) ? (double)WindowSize/dt : 0;
   price_velocity = (dt>0) ? (midNow-midAgo)/dt : 0;

   PushVel(price_velocity);
   price_acceleration = (g_velCount > AccelLookback) ? (price_velocity - VelAgo(AccelLookback)) : 0;

   double spreadSum=0, spreadSumSq=0;
   double midSum=0, midSumSq=0;
   int upTicks=0;
   for(int i=0; i<WindowSize; i++)
   {
      double sp = BufSpread(i);
      spreadSum += sp; spreadSumSq += sp*sp;

      double m = BufMid(i);
      midSum += m; midSumSq += m*m;
      if(i < WindowSize-1)
      {
         double mPrev = BufMid(i+1);
         if(m > mPrev) upTicks++;
      }
   }
   double meanSpread = spreadSum/WindowSize;
   double varSpread  = spreadSumSq/WindowSize - meanSpread*meanSpread;
   double stdSpread  = (varSpread>0) ? MathSqrt(varSpread) : 0;
   spread_zscore = (spreadNow-meanSpread)/(stdSpread+0.00000001);

   tick_direction_ratio = (double)upTicks/(WindowSize-1);

   double meanMid = midSum/WindowSize;
   double varMid  = midSumSq/WindowSize - meanMid*meanMid;
   micro_volatility = (varMid>0) ? MathSqrt(varMid) : 0;

   return true;
}

//=========================== TRAINING DATA LOGGER ================================//
// Logs a feature snapshot on a sample of ticks, then LabelLookaheadTicks
// later writes the realized forward price move as the label - entirely
// independent of any trade the EA does or doesn't take, since there is no
// rule-based fallback signal here to log a "setup" from the way
// QuantixApexEA does. This is how the first model gets bootstrapped.
int OpenTrainingLogFile()
{
   bool isNew = !FileIsExist(TrainingLogFileName, FILE_COMMON);
   int handle = FileOpen(TrainingLogFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(handle==INVALID_HANDLE)
   {
      Print("QuantixFlowEA: failed to open training log, err=", GetLastError());
      return INVALID_HANDLE;
   }
   FileSeek(handle, 0, SEEK_END);
   if(isNew)
      FileWrite(handle, "time","tick_velocity","price_velocity","price_acceleration",
                "spread_zscore","tick_direction_ratio","micro_volatility","forward_return_points");
   return handle;
}

void UpdateTrainingLogger(double midNow, double tick_velocity, double price_velocity, double price_acceleration,
                           double spread_zscore, double tick_direction_ratio, double micro_volatility)
{
   for(int i=0; i<g_pendingCount; i++)
   {
      g_pending[i].age++;
      if(g_pending[i].age >= LabelLookaheadTicks)
      {
         double forwardReturn = (midNow - g_pending[i].refMid) / _Point;
         if(g_TrainingLogHandle != INVALID_HANDLE)
         {
            FileWrite(g_TrainingLogHandle, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                      g_pending[i].tick_velocity, g_pending[i].price_velocity, g_pending[i].price_acceleration,
                      g_pending[i].spread_zscore, g_pending[i].tick_direction_ratio, g_pending[i].micro_volatility,
                      forwardReturn);
         }
         // Order doesn't matter here, so swap-remove instead of shifting the array.
         g_pending[i] = g_pending[g_pendingCount-1];
         g_pendingCount--;
         i--;
      }
   }

   if(g_tickCounter % LogSampleEveryNTicks == 0)
   {
      if(g_pendingCount >= ArraySize(g_pending))
         ArrayResize(g_pending, ArraySize(g_pending)+500);
      g_pending[g_pendingCount].refMid               = midNow;
      g_pending[g_pendingCount].tick_velocity         = tick_velocity;
      g_pending[g_pendingCount].price_velocity        = price_velocity;
      g_pending[g_pendingCount].price_acceleration    = price_acceleration;
      g_pending[g_pendingCount].spread_zscore         = spread_zscore;
      g_pending[g_pendingCount].tick_direction_ratio  = tick_direction_ratio;
      g_pending[g_pendingCount].micro_volatility      = micro_volatility;
      g_pending[g_pendingCount].age                   = 0;
      g_pendingCount++;
   }
}

//=========================== RISK / SIZING ================================//
// Same contract-size-based formula as QuantixApexEA - that EA's earlier 10x
// mis-sizing bug came from trusting SYMBOL_TRADE_TICK_VALUE/TICK_SIZE, which
// didn't match this broker's real fills; SYMBOL_TRADE_CONTRACT_SIZE did.
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
   if(lot < minLotAllowed)
   {
      if(!AllowMinLotOverride) return 0;
      lot = minLotAllowed;
   }
   lot = MathMin(lot, MathMin(MaxLot, volMax));
   return NormalizeDouble(lot, 2);
}

//=========================== MODEL INFERENCE ================================//
// Class order out of onnxmltools/LightGBM follows sorted labels: [-1,0,1] ->
// index0=down, index1=flat, index2=up (train_flow_model.py trains on those
// exact integer labels, so this must stay in sync with it).
bool RunModel(double tick_velocity, double price_velocity, double price_acceleration,
              double spread_zscore, double tick_direction_ratio, double micro_volatility,
              double &probBuy, double &probSell)
{
   if(g_OnnxHandle == INVALID_HANDLE) return false;

   float featVec[6];
   featVec[0] = (float)tick_velocity;
   featVec[1] = (float)price_velocity;
   featVec[2] = (float)price_acceleration;
   featVec[3] = (float)spread_zscore;
   featVec[4] = (float)tick_direction_ratio;
   featVec[5] = (float)micro_volatility;

   long  labelOut[1];
   float probOut[3];

   if(!OnnxRun(g_OnnxHandle, ONNX_DEFAULT, featVec, labelOut, probOut))
   {
      Print("QuantixFlowEA: OnnxRun failed, err=", GetLastError());
      return false;
   }
   probSell = probOut[0]; // P(down)
   probBuy  = probOut[2]; // P(up)
   return true;
}

//=========================== TRADE EXECUTION ================================//
bool OpenTrade(int bias)
{
   double price = (bias==1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point * 1.1;
   double slDistance = MathMax(SL_Points*_Point, minDist);
   double tpDistance = MathMax(TP_Points*_Point, minDist);

   double lot = CalcLot(slDistance);
   if(lot<=0)
   {
      Print("QuantixFlowEA: skipped entry - SL too wide for RiskPercent at min lot (slDistance=", slDistance, ")");
      return false;
   }

   double sl = (bias==1) ? price-slDistance : price+slDistance;
   double tp = (bias==1) ? price+tpDistance : price-tpDistance;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   string cmt = (Language==LNG_TH) ? (bias==1?"Flow ซื้อ":"Flow ขาย") : (bias==1?"Flow BUY":"Flow SELL");
   bool ok = (bias==1) ? trade.Buy(lot, _Symbol, price, sl, tp, cmt)
                        : trade.Sell(lot, _Symbol, price, sl, tp, cmt);
   if(!ok)
   {
      Print("QuantixFlowEA: order send failed, retcode=", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      return false;
   }
   Print("QuantixFlowEA: opened ", (bias==1?"BUY":"SELL"), " lot=", lot, " price=", price, " sl=", sl, " tp=", tp,
         " probBuy=", DoubleToString(g_lastProbBuy,3), " probSell=", DoubleToString(g_lastProbSell,3));
   return true;
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
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 300);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 150);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'20,20,20');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   }
}

void UpdateDashboard()
{
   if(!EffectiveShowDashboard()) return;
   CreateDashboard();
   int x=Dashboard_X, y=Dashboard_Y, rh=16;

   DashLabel("title", "QuantixFlowEA", x, y, clrWhite, 10); y+=rh+4;
   DashLabel("ai", UseAIModel ? (g_OnnxHandle!=INVALID_HANDLE?"AI: Loaded":"AI: FAILED TO LOAD") : "AI: Off (no trades)",
             x, y, (UseAIModel && g_OnnxHandle==INVALID_HANDLE)?clrTomato:clrWhite); y+=rh;
   DashLabel("prob", StringFormat("Buy:%.2f  Sell:%.2f", g_lastProbBuy, g_lastProbSell), x, y, clrWhite); y+=rh;
   DashLabel("pending", StringFormat((Language==LNG_TH?"รอบันทึกผล: %d":"Pending labels: %d"), g_pendingCount), x, y, clrWhite); y+=rh;

   bool hasPos = PositionSelectForMagic();
   DashLabel("pos", hasPos?(Language==LNG_TH?"มีไม้เปิดอยู่":"Position: OPEN"):(Language==LNG_TH?"ไม่มีไม้เปิด":"Position: none"),
             x, y, hasPos?Dashboard_Green():clrWhite); y+=rh;
   DashLabel("daily", g_dailyHalted?("HALTED: "+g_haltReason):(Language==LNG_TH?"รายวัน: ปกติ":"Daily: OK"),
             x, y, g_dailyHalted?clrTomato:clrWhite); y+=rh;
   DashLabel("dd", g_ddGuardHalted?("HALTED: "+g_ddGuardReason):(Language==LNG_TH?"DD Guard: ปกติ":"DD Guard: OK"),
             x, y, g_ddGuardHalted?clrTomato:clrWhite); y+=rh;
}

color Dashboard_Green() { return clrLimeGreen; }

//+------------------------------------------------------------------+
void OnTick()
{
   ManageNewDay();
   CheckTotalDDGuard();

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   if(tick.bid<=0 || tick.ask<=0) return;

   double mid    = (tick.bid+tick.ask)/2.0;
   double spread = tick.ask-tick.bid;
   double timeSec = tick.time_msc/1000.0;

   PushTick(mid, spread, timeSec);
   g_tickCounter++;

   double tick_velocity=0, price_velocity=0, price_acceleration=0;
   double spread_zscore=0, tick_direction_ratio=0, micro_volatility=0;
   double midNow=0, spreadNow=0;
   bool haveFeatures = ComputeFeatures(tick_velocity, price_velocity, price_acceleration,
                                        spread_zscore, tick_direction_ratio, micro_volatility,
                                        midNow, spreadNow);

   if(UseTrainingLogger && haveFeatures)
      UpdateTrainingLogger(midNow, tick_velocity, price_velocity, price_acceleration,
                            spread_zscore, tick_direction_ratio, micro_volatility);

   if(EffectiveShowDashboard()) UpdateDashboard();

   if(!haveFeatures) return;
   if(g_dailyHalted || g_ddGuardHalted) return;
   if(!UseAIModel || g_OnnxHandle==INVALID_HANDLE) return;
   if(PositionSelectForMagic()) return;
   if(!IsWithinSession()) return;
   if(spreadNow/_Point > MaxSpreadPoints) return;

   double probBuy=0, probSell=0;
   if(!RunModel(tick_velocity, price_velocity, price_acceleration, spread_zscore, tick_direction_ratio, micro_volatility, probBuy, probSell))
      return;
   g_lastProbBuy  = probBuy;
   g_lastProbSell = probSell;

   if(probBuy >= MinBuyProbability)
      OpenTrade(1);
   else if(probSell >= MinSellProbability)
      OpenTrade(-1);
}
