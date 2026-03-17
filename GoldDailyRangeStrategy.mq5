//+------------------------------------------------------------------+
//|                   XAUUSD Daily Range Strategy                    |
//|                     Pepperstone MT5 Platform                     |
//|                                                                  |
//|  Logic:                                                          |
//|  - D1[1] High = Buy Level,  D1[1] Low = Sell Level              |
//|  - Observation window (00:00 → start time):                      |
//|      Ask >= High → block Buys for the day                        |
//|      Bid <= Low  → block Sells for the day                       |
//|  - Trading window (start time → end time):                       |
//|      Ask crosses above High → Buy market order (spread check)    |
//|      Bid crosses below Low  → Sell market order (spread check)   |
//|  - One trade per day; entering a Buy blocks Sells and vice-versa |
//|  - SL/TP anchored to D1[1] High or Low (not fill price)         |
//|  - Monday: extra observation hour before entries are allowed      |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Daily Range Strategy"
#property version   "2.00"
#property description "Market orders on D1 High/Low crossovers (Pepperstone, UTC+2)"

#include <Trade\Trade.mqh>

//=== Inputs =========================================================

input group "== Trading Hours (UTC+2 Broker Server Time) =="
input int    InpTueFriStartHour = 1;        // Tue-Fri Start Hour  (01:00)
input int    InpTueFriStartMin  = 0;        // Tue-Fri Start Minute
input int    InpMonStartHour    = 2;        // Monday Start Hour   (02:00)
input int    InpMonStartMin     = 0;        // Monday Start Minute
input int    InpEndHour         = 19;       // End Hour            (19:00)
input int    InpEndMin          = 0;        // End Minute

input group "== Strategy Parameters =="
input double InpRangePercent    = 10.0;     // SL: % of D1[1] range
input double InpRiskReward      = 1.0;      // TP: Risk-to-Reward ratio
input double InpRiskPercent     = 1.0;      // Risk: % of account balance per trade
input double InpMaxSpreadPoints = 30.0;     // Max spread in points for entry

input group "== EA Settings =="
input long   InpMagicNumber     = 20240101; // EA Magic Number

//=== Globals ========================================================

CTrade trade;

// Session levels
double g_prevHigh = 0.0;
double g_prevLow  = 0.0;
double g_slDist   = 0.0;   // SL distance in price units (10% of D1[1] range)
double g_tpDist   = 0.0;   // TP distance in price units (slDist * R:R)

// Direction gates
bool g_buyBlocked  = false;  // Buy direction disabled for today
bool g_sellBlocked = false;  // Sell direction disabled for today
bool g_tradedToday = false;  // A trade has already been entered today

// Cross detection: store previous tick's prices
double g_lastAsk = 0.0;
double g_lastBid = 0.0;

// Session / day state
bool g_sessionReady = false;
bool g_cleanupDone  = false;
int  g_lastServerDay = -1;

//+------------------------------------------------------------------+
//| Server time helpers                                               |
//+------------------------------------------------------------------+
MqlDateTime GetSrvDT() { MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); return dt; }
bool SrvTimeGE(int h, int m, const MqlDateTime &dt) { return dt.hour > h || (dt.hour == h && dt.min >= m); }
bool SrvTimeLT(int h, int m, const MqlDateTime &dt) { return dt.hour < h || (dt.hour == h && dt.min <  m); }

//+------------------------------------------------------------------+
//| Load D1[1] High/Low; compute SL and TP distances                 |
//+------------------------------------------------------------------+
bool LoadSessionData()
{
   double hi = 0, lo = 0;
   for (int i = 0; i < 5; i++)
   {
      hi = iHigh(_Symbol, PERIOD_D1, 1);
      lo = iLow (_Symbol, PERIOD_D1, 1);
      if (hi > 0 && lo > 0 && hi > lo) break;
      Sleep(200);
   }
   if (hi <= 0 || lo <= 0 || hi <= lo) return false;

   double range = hi - lo;
   g_prevHigh   = hi;
   g_prevLow    = lo;
   g_slDist     = range * InpRangePercent / 100.0;
   g_tpDist     = g_slDist * InpRiskReward;
   return true;
}

//+------------------------------------------------------------------+
//| Lot sizing: risk InpRiskPercent of balance on this SL distance   |
//+------------------------------------------------------------------+
double CalcLots(double slDist)
{
   if (slDist <= 0.0) return 0.0;

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt    = balance * InpRiskPercent / 100.0;
   double tickSz     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if (tickSz <= 0.0 || tickVal <= 0.0) return 0.0;

   double valPerUnit = tickVal / tickSz;
   double lots       = riskAmt / (slDist * valPerUnit);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   return MathMax(minL, MathMin(maxL, lots));
}

//+------------------------------------------------------------------+
//| Spread filter: returns true if current spread is within limit     |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if (spread <= InpMaxSpreadPoints) return true;
   PrintFormat("Spread filter: %.0f pts > max %.0f — entry skipped.", spread, InpMaxSpreadPoints);
   return false;
}

//+------------------------------------------------------------------+
//| Enter Buy market order                                            |
//| SL and TP anchored to D1[1] High (not fill price)                |
//+------------------------------------------------------------------+
void EnterBuy()
{
   if (!SpreadOK()) return;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double lots   = CalcLots(g_slDist);
   if (lots <= 0.0) { Print("Lot calc failed — Buy skipped."); return; }

   double sl = NormalizeDouble(g_prevHigh - g_slDist, digits);
   double tp = NormalizeDouble(g_prevHigh + g_tpDist, digits);

   if (trade.Buy(lots, _Symbol, 0, sl, tp, "GS_Buy"))
   {
      double fill = trade.ResultPrice();
      PrintFormat("BUY entered | Fill=%.2f | SL=%.2f | TP=%.2f | Lots=%.2f", fill, sl, tp, lots);
      g_tradedToday = true;
      g_sellBlocked = true;   // In a Buy → no Sells for today
   }
   else
      PrintFormat("Buy market FAILED. Err=%d", GetLastError());
}

//+------------------------------------------------------------------+
//| Enter Sell market order                                           |
//| SL and TP anchored to D1[1] Low (not fill price)                 |
//+------------------------------------------------------------------+
void EnterSell()
{
   if (!SpreadOK()) return;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double lots   = CalcLots(g_slDist);
   if (lots <= 0.0) { Print("Lot calc failed — Sell skipped."); return; }

   double sl = NormalizeDouble(g_prevLow + g_slDist, digits);
   double tp = NormalizeDouble(g_prevLow - g_tpDist, digits);

   if (trade.Sell(lots, _Symbol, 0, sl, tp, "GS_Sell"))
   {
      double fill = trade.ResultPrice();
      PrintFormat("SELL entered | Fill=%.2f | SL=%.2f | TP=%.2f | Lots=%.2f", fill, sl, tp, lots);
      g_tradedToday = true;
      g_buyBlocked = true;   // In a Sell → no Buys for today
   }
   else
      PrintFormat("Sell market FAILED. Err=%d", GetLastError());
}

//+------------------------------------------------------------------+
//| Scan open positions to restore state after EA restart            |
//+------------------------------------------------------------------+
void ScanOpenPositions()
{
   for (int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if (!PositionSelectByTicket(ticket))                         continue;
      if (PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)    continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol)           continue;

      g_tradedToday = true;
      long type = PositionGetInteger(POSITION_TYPE);
      if (type == POSITION_TYPE_BUY)
      {
         g_sellBlocked = true;
         Print("Init: Existing Buy position found — Sells blocked.");
      }
      else if (type == POSITION_TYPE_SELL)
      {
         g_buyBlocked = true;
         Print("Init: Existing Sell position found — Buys blocked.");
      }
      break;
   }
}

//+------------------------------------------------------------------+
//| Reset all session state and load new D1[1] data                  |
//+------------------------------------------------------------------+
void NewSession(int serverDOW)
{
   g_prevHigh    = 0.0;  g_prevLow     = 0.0;
   g_slDist      = 0.0;  g_tpDist      = 0.0;
   g_buyBlocked  = false; g_sellBlocked = false;
   g_tradedToday = false;
   g_sessionReady = false;
   g_cleanupDone  = false;

   // Seed cross-detection prices so first tick doesn't produce a false cross
   g_lastAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   g_lastBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if (serverDOW == 0 || serverDOW == 6) return;   // Weekend — no trading

   if (!LoadSessionData())
   {
      Print("Session setup failed — invalid D1[1] candle data.");
      return;
   }

   g_sessionReady = true;
   PrintFormat("New session [DOW=%d] | High=%.2f | Low=%.2f | SL=%.2f | TP=%.2f",
               serverDOW, g_prevHigh, g_prevLow, g_slDist, g_tpDist);
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   MqlDateTime srvDT = GetSrvDT();
   g_lastServerDay = srvDT.day;

   // Resume mid-session if EA starts on a weekday
   if (srvDT.day_of_week >= 1 && srvDT.day_of_week <= 5)
   {
      if (LoadSessionData())
      {
         g_sessionReady = true;
         g_lastAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         g_lastBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         // Restore trade/block state from any existing open position
         ScanOpenPositions();

         // If no open position, apply conservative breach check from current price
         if (!g_tradedToday)
         {
            if (g_lastAsk >= g_prevHigh) { g_buyBlocked  = true; Print("Init: Ask >= High — Buys blocked."); }
            if (g_lastBid <= g_prevLow)  { g_sellBlocked = true; Print("Init: Bid <= Low  — Sells blocked."); }
         }

         // If already past end time, mark cleanup done
         if (SrvTimeGE(InpEndHour, InpEndMin, srvDT))
            g_cleanupDone = true;

         PrintFormat("EA resumed mid-session [DOW=%d] | High=%.2f | Low=%.2f | Traded=%s",
                     srvDT.day_of_week, g_prevHigh, g_prevLow,
                     g_tradedToday ? "Yes" : "No");
      }
   }

   Print("Gold Strategy EA v2 initialised. Magic=", InpMagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA stopped. Reason=", reason);
}

//+------------------------------------------------------------------+
//| OnTick — Main state machine                                       |
//|                                                                   |
//| Phases (all times in UTC+2 broker server time):                   |
//|  [00:00 – StartTime]   Observation — detect direction breaches    |
//|  [StartTime – EndTime] Trading     — fire market orders on cross  |
//|  [EndTime+]            Done        — flag cleanup                 |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlDateTime srvDT = GetSrvDT();

   //--- Detect Pepperstone daily rollover (00:00 UTC+2)
   if (srvDT.day != g_lastServerDay)
   {
      g_lastServerDay = srvDT.day;
      NewSession(srvDT.day_of_week);
   }

   if (!g_sessionReady || srvDT.day_of_week == 0 || srvDT.day_of_week == 6)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool isMonday  = (srvDT.day_of_week == 1);
   int  sH = isMonday ? InpMonStartHour    : InpTueFriStartHour;
   int  sM = isMonday ? InpMonStartMin     : InpTueFriStartMin;

   bool inObs     = SrvTimeLT(sH, sM,                          srvDT);
   bool inTrading = SrvTimeGE(sH, sM, srvDT) && SrvTimeLT(InpEndHour, InpEndMin, srvDT);
   bool pastEnd   = SrvTimeGE(InpEndHour, InpEndMin,           srvDT);

   //----------------------------------------------------------------
   // Phase 1 — Observation window
   // Track whether price breaches D1[1] High or Low before trading
   // starts. For Monday this covers the extra waiting hour.
   //----------------------------------------------------------------
   if (inObs)
   {
      if (!g_buyBlocked && ask >= g_prevHigh)
      {
         g_buyBlocked = true;
         PrintFormat("Obs: Ask %.2f >= High %.2f — Buys blocked for today.", ask, g_prevHigh);
      }
      if (!g_sellBlocked && bid <= g_prevLow)
      {
         g_sellBlocked = true;
         PrintFormat("Obs: Bid %.2f <= Low %.2f — Sells blocked for today.", bid, g_prevLow);
      }
   }

   //----------------------------------------------------------------
   // Phase 2 — Trading window
   // Watch for Ask crossing above High (Buy) or Bid crossing below
   // Low (Sell). Only one trade per day.
   //----------------------------------------------------------------
   else if (inTrading && !g_tradedToday)
   {
      // Buy: Ask crosses above D1[1] High
      if (!g_buyBlocked && g_lastAsk <= g_prevHigh && ask > g_prevHigh)
         EnterBuy();

      // Sell: Bid crosses below D1[1] Low (re-check tradedToday in case Buy just fired)
      if (!g_sellBlocked && !g_tradedToday && g_lastBid >= g_prevLow && bid < g_prevLow)
         EnterSell();
   }

   //----------------------------------------------------------------
   // Phase 3 — Past end time
   //----------------------------------------------------------------
   else if (pastEnd && !g_cleanupDone)
   {
      PrintFormat("Trading window closed (%02d:%02d UTC+2).", InpEndHour, InpEndMin);
      g_cleanupDone = true;
   }

   // Store current prices for next tick's cross detection
   g_lastAsk = ask;
   g_lastBid = bid;
}
//+------------------------------------------------------------------+
