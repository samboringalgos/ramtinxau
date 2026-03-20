//+------------------------------------------------------------------+
//|                   XAUUSD Daily Range Strategy                    |
//|                     Pepperstone MT5 Platform                     |
//|                                                                  |
//|  Logic:                                                          |
//|  - D1[1] High = Buy Level,  D1[1] Low = Sell Level              |
//|  - Observation window (00:00 → start time):                      |
//|      Bid >= High → block Buys for the day                        |
//|      Bid <= Low  → block Sells for the day                       |
//|  - Trading window (start time → end time):                       |
//|      Bid crosses above High → arm Buy; retry entry each tick     |
//|      Bid crosses below Low  → arm Sell; retry entry each tick    |
//|      Armed entry retries until success or price retreats         |
//|  - One trade per day; entering a Buy blocks Sells and vice-versa |
//|  - SL/TP anchored to D1[1] High or Low (not fill price)         |
//|  - Monday: extra observation hour before entries are allowed     |
//|                                                                  |
//|  Note: All input hours are in broker server time. Pepperstone    |
//|  uses EET (UTC+2 winter, UTC+3 summer). If DST causes trading    |
//|  windows to drift vs intended NY/London times, adjust the input  |
//|  hours manually after each DST transition.                       |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Daily Range Strategy"
#property version   "3.00"
#property description "Market orders on D1 High/Low crossovers (Pepperstone)"

#include <Trade\Trade.mqh>

//=== Inputs =========================================================

input group "== Trading Hours (Broker Server Time) =="
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

input group "== Order Settings =="
input int    InpDeviationPoints = 50;       // Max slippage (points) accepted on fill
input long   InpMagicNumber     = 20240101; // EA Magic Number

//=== Globals ========================================================

CTrade trade;

// Session levels (from D1[1], loaded at midnight)
double g_prevHigh = 0.0;
double g_prevLow  = 0.0;
double g_slDist   = 0.0;  // SL distance: InpRangePercent% of D1[1] range
double g_tpDist   = 0.0;  // TP distance: slDist × InpRiskReward

// Direction gates
bool g_buyBlocked  = false;  // Buy  direction disabled for today
bool g_sellBlocked = false;  // Sell direction disabled for today
bool g_tradedToday = false;  // A trade has already been entered today

// Cross-detection (D1 bars are bid-based; bid used throughout)
double g_lastBid = 0.0;

// Armed flags: set on a valid cross, cleared on successful entry or price retreat.
// Allows entry to be retried every tick after a failed attempt (spread, stop level, etc.)
bool g_buyCrossArmed  = false;
bool g_sellCrossArmed = false;

// Session / day state
bool g_sessionReady  = false;
bool g_needsDataLoad = false;  // True when day rolled but D1[1] not yet ready
bool g_cleanupDone   = false;
int  g_lastServerDay = -1;

//+------------------------------------------------------------------+
//| Server time helpers                                               |
//+------------------------------------------------------------------+
MqlDateTime GetSrvDT() { MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); return dt; }
bool SrvTimeGE(int h, int m, const MqlDateTime &dt) { return dt.hour > h || (dt.hour == h && dt.min >= m); }
bool SrvTimeLT(int h, int m, const MqlDateTime &dt) { return dt.hour < h || (dt.hour == h && dt.min <  m); }

//+------------------------------------------------------------------+
//| Single non-blocking attempt to load D1[1] High/Low.             |
//| Returns true on success. No Sleep() — safe to call from OnTick.  |
//+------------------------------------------------------------------+
bool TryLoadSessionData()
{
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow (_Symbol, PERIOD_D1, 1);
   if (hi <= 0 || lo <= 0 || hi <= lo) return false;

   double range = hi - lo;
   g_prevHigh   = hi;
   g_prevLow    = lo;
   g_slDist     = range * InpRangePercent / 100.0;
   g_tpDist     = g_slDist * InpRiskReward;
   return true;
}

//+------------------------------------------------------------------+
//| Blocking load with retries — only call from OnInit where         |
//| Sleep() is permitted. Tries up to 10 times with 100ms gaps.     |
//+------------------------------------------------------------------+
bool LoadSessionDataWithRetry()
{
   for (int i = 0; i < 10; i++)
   {
      if (TryLoadSessionData()) return true;
      Sleep(100);
   }
   return false;
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
//| Spread filter: true if spread is within limit                    |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if (spread <= InpMaxSpreadPoints) return true;
   PrintFormat("Spread filter: %.0f pts > max %.0f — entry skipped.", spread, InpMaxSpreadPoints);
   return false;
}

//+------------------------------------------------------------------+
//| Stop level check: true if SL and TP are both far enough from     |
//| the estimated entry price to satisfy the broker's minimum.       |
//+------------------------------------------------------------------+
bool StopLevelOK(double entryPrice, double sl, double tp)
{
   long   lvl     = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = lvl * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if (minDist <= 0.0) return true;

   double slDist = MathAbs(entryPrice - sl);
   double tpDist = MathAbs(tp - entryPrice);
   if (slDist < minDist || tpDist < minDist)
   {
      PrintFormat("Stop level violation: min=%.5f | SL dist=%.5f | TP dist=%.5f — skipped.",
                  minDist, slDist, tpDist);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Enter Buy market order                                            |
//| SL and TP anchored to D1[1] High                                 |
//+------------------------------------------------------------------+
void EnterBuy()
{
   if (!SpreadOK()) return;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double lots   = CalcLots(g_slDist);
   if (lots <= 0.0) { Print("Lot calc failed — Buy skipped."); return; }

   double sl  = NormalizeDouble(g_prevHigh - g_slDist, digits);
   double tp  = NormalizeDouble(g_prevHigh + g_tpDist, digits);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if (!StopLevelOK(ask, sl, tp)) return;

   if (trade.Buy(lots, _Symbol, 0, sl, tp, "GS_Buy"))
   {
      PrintFormat("BUY entered | Fill=%.2f | SL=%.2f | TP=%.2f | Lots=%.2f",
                  trade.ResultPrice(), sl, tp, lots);
      g_tradedToday   = true;
      g_sellBlocked   = true;
      g_buyCrossArmed = false;
   }
   else
      PrintFormat("Buy market FAILED. Err=%d — will retry next tick if price holds.", GetLastError());
}

//+------------------------------------------------------------------+
//| Enter Sell market order                                           |
//| SL and TP anchored to D1[1] Low                                  |
//+------------------------------------------------------------------+
void EnterSell()
{
   if (!SpreadOK()) return;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double lots   = CalcLots(g_slDist);
   if (lots <= 0.0) { Print("Lot calc failed — Sell skipped."); return; }

   double sl  = NormalizeDouble(g_prevLow + g_slDist, digits);
   double tp  = NormalizeDouble(g_prevLow - g_tpDist, digits);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if (!StopLevelOK(bid, sl, tp)) return;

   if (trade.Sell(lots, _Symbol, 0, sl, tp, "GS_Sell"))
   {
      PrintFormat("SELL entered | Fill=%.2f | SL=%.2f | TP=%.2f | Lots=%.2f",
                  trade.ResultPrice(), sl, tp, lots);
      g_tradedToday    = true;
      g_buyBlocked     = true;
      g_sellCrossArmed = false;
   }
   else
      PrintFormat("Sell market FAILED. Err=%d — will retry next tick if price holds.", GetLastError());
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
         Print("Init: Existing Buy position — Sells blocked.");
      }
      else if (type == POSITION_TYPE_SELL)
      {
         g_buyBlocked = true;
         Print("Init: Existing Sell position — Buys blocked.");
      }
      break;
   }
}

//+------------------------------------------------------------------+
//| Scan today's deal history for a completed EA trade.              |
//| Catches the case where a position hit TP/SL before EA restarted. |
//+------------------------------------------------------------------+
void ScanTodayHistory()
{
   // Build today's midnight datetime in broker server time
   MqlDateTime srvDT = GetSrvDT();
   srvDT.hour = 0; srvDT.min = 0; srvDT.sec = 0;
   datetime dayStart = StructToTime(srvDT);

   if (!HistorySelect(dayStart, TimeCurrent())) return;

   for (int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if (!HistoryDealSelect(ticket))                                       continue;
      if (HistoryDealGetInteger(ticket, DEAL_MAGIC)  != InpMagicNumber)     continue;
      if (HistoryDealGetString (ticket, DEAL_SYMBOL) != _Symbol)            continue;
      if (HistoryDealGetInteger(ticket, DEAL_ENTRY)  != DEAL_ENTRY_IN)      continue;

      // A position-opening deal was placed today by this EA
      g_tradedToday = true;
      long type = HistoryDealGetInteger(ticket, DEAL_TYPE);
      if (type == DEAL_TYPE_BUY)  { g_sellBlocked = true; Print("Init: Closed Buy in history — Sells blocked."); }
      if (type == DEAL_TYPE_SELL) { g_buyBlocked  = true; Print("Init: Closed Sell in history — Buys blocked."); }
      break;
   }
}

//+------------------------------------------------------------------+
//| Reset all session state. D1[1] data load is attempted            |
//| immediately; deferred to next tick if not yet ready.             |
//+------------------------------------------------------------------+
void NewSession(int serverDOW)
{
   g_prevHigh       = 0.0;  g_prevLow       = 0.0;
   g_slDist         = 0.0;  g_tpDist        = 0.0;
   g_buyBlocked     = false; g_sellBlocked   = false;
   g_tradedToday    = false;
   g_buyCrossArmed  = false; g_sellCrossArmed = false;
   g_sessionReady   = false;
   g_needsDataLoad  = false;
   g_cleanupDone    = false;

   // Seed cross-detection bid at rollover to prevent a false cross on the first tick
   g_lastBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if (serverDOW == 0 || serverDOW == 6) return;  // Weekend — no trading

   if (TryLoadSessionData())
   {
      g_sessionReady = true;
      PrintFormat("New session [DOW=%d] | High=%.2f | Low=%.2f | SL=%.2f | TP=%.2f",
                  serverDOW, g_prevHigh, g_prevLow, g_slDist, g_tpDist);
   }
   else
   {
      g_needsDataLoad = true;
      PrintFormat("New session [DOW=%d] | D1[1] not ready — will retry next tick.", serverDOW);
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);  // Query broker for supported fill mode

   MqlDateTime srvDT = GetSrvDT();
   g_lastServerDay = srvDT.day;

   // Resume mid-session if EA starts on a weekday
   if (srvDT.day_of_week >= 1 && srvDT.day_of_week <= 5)
   {
      if (LoadSessionDataWithRetry())
      {
         g_sessionReady = true;
         g_lastBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         // Step 1: check for an open position from this EA
         ScanOpenPositions();

         // Step 2: if no open position, check deal history for a completed trade today
         if (!g_tradedToday)
            ScanTodayHistory();

         // Step 3: if still no trade recorded, apply observation-window breach check —
         //         but ONLY if we are still within the observation window right now.
         //         During the trading window, the cross-detection logic handles blocking;
         //         applying a price-based block here would prevent valid entries.
         if (!g_tradedToday)
         {
            bool isMonday = (srvDT.day_of_week == 1);
            int  sH = isMonday ? InpMonStartHour : InpTueFriStartHour;
            int  sM = isMonday ? InpMonStartMin  : InpTueFriStartMin;

            if (SrvTimeLT(sH, sM, srvDT))  // Still in observation window
            {
               if (g_lastBid >= g_prevHigh) { g_buyBlocked  = true; Print("Init: Bid >= High in obs window — Buys blocked."); }
               if (g_lastBid <= g_prevLow)  { g_sellBlocked = true; Print("Init: Bid <= Low in obs window — Sells blocked."); }
            }
         }

         if (SrvTimeGE(InpEndHour, InpEndMin, srvDT))
            g_cleanupDone = true;

         PrintFormat("EA resumed [DOW=%d] | High=%.2f | Low=%.2f | Traded=%s | BuyBlocked=%s | SellBlocked=%s",
                     srvDT.day_of_week, g_prevHigh, g_prevLow,
                     g_tradedToday  ? "Yes" : "No",
                     g_buyBlocked   ? "Yes" : "No",
                     g_sellBlocked  ? "Yes" : "No");
      }
   }

   Print("Gold Strategy EA v3 initialised. Magic=", InpMagicNumber);
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
//| Phases (all times in broker server time):                         |
//|  [00:00 – StartTime]   Observation — block direction on breach   |
//|  [StartTime – EndTime] Trading     — arm on cross, retry entry   |
//|  [EndTime+]            Done        — disarm and log              |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlDateTime srvDT = GetSrvDT();

   //--- Detect Pepperstone daily rollover (midnight broker server time)
   if (srvDT.day != g_lastServerDay)
   {
      g_lastServerDay = srvDT.day;
      NewSession(srvDT.day_of_week);
   }

   //--- Deferred D1[1] load: retry each tick without any Sleep()
   if (g_needsDataLoad)
   {
      if (TryLoadSessionData())
      {
         g_needsDataLoad = false;
         g_sessionReady  = true;
         PrintFormat("Session data loaded on retry | High=%.2f | Low=%.2f | SL=%.2f | TP=%.2f",
                     g_prevHigh, g_prevLow, g_slDist, g_tpDist);
      }
      else return;  // Not ready yet — try again next tick
   }

   if (!g_sessionReady || srvDT.day_of_week == 0 || srvDT.day_of_week == 6)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool isMonday  = (srvDT.day_of_week == 1);
   int  sH = isMonday ? InpMonStartHour : InpTueFriStartHour;
   int  sM = isMonday ? InpMonStartMin  : InpTueFriStartMin;

   bool inObs     = SrvTimeLT(sH, sM,                          srvDT);
   bool inTrading = SrvTimeGE(sH, sM, srvDT) && SrvTimeLT(InpEndHour, InpEndMin, srvDT);
   bool pastEnd   = SrvTimeGE(InpEndHour, InpEndMin,           srvDT);

   //----------------------------------------------------------------
   // Phase 1 — Observation window
   // Block a direction permanently for today if bid touches or
   // crosses the level before the trading window opens.
   //----------------------------------------------------------------
   if (inObs)
   {
      if (!g_buyBlocked && bid >= g_prevHigh)
      {
         g_buyBlocked = true;
         PrintFormat("Obs: Bid %.2f >= High %.2f — Buys blocked for today.", bid, g_prevHigh);
      }
      if (!g_sellBlocked && bid <= g_prevLow)
      {
         g_sellBlocked = true;
         PrintFormat("Obs: Bid %.2f <= Low %.2f — Sells blocked for today.", bid, g_prevLow);
      }
   }

   //----------------------------------------------------------------
   // Phase 2 — Trading window
   //
   // A fresh bid cross arms the direction. While armed:
   //   - entry is attempted every tick (handles spread/stop-level retries)
   //   - if price retreats back through the level, the arm is cleared
   //   - successful entry sets g_tradedToday and clears the arm
   //----------------------------------------------------------------
   else if (inTrading && !g_tradedToday)
   {
      // Arm on fresh cross
      if (!g_buyBlocked && g_lastBid <= g_prevHigh && bid > g_prevHigh)
      {
         g_buyCrossArmed = true;
         PrintFormat("Buy cross: LastBid=%.2f → Bid=%.2f vs High=%.2f — armed.",
                     g_lastBid, bid, g_prevHigh);
      }
      if (!g_sellBlocked && g_lastBid >= g_prevLow && bid < g_prevLow)
      {
         g_sellCrossArmed = true;
         PrintFormat("Sell cross: LastBid=%.2f → Bid=%.2f vs Low=%.2f — armed.",
                     g_lastBid, bid, g_prevLow);
      }

      // Disarm if price retreated back through the level
      if (g_buyCrossArmed  && bid <= g_prevHigh) { g_buyCrossArmed  = false; Print("Buy cross retreated — disarmed."); }
      if (g_sellCrossArmed && bid >= g_prevLow)  { g_sellCrossArmed = false; Print("Sell cross retreated — disarmed."); }

      // Attempt entry while armed (retries automatically on failure)
      if (g_buyCrossArmed  && !g_tradedToday) EnterBuy();
      if (g_sellCrossArmed && !g_tradedToday) EnterSell();
   }

   //----------------------------------------------------------------
   // Phase 3 — Past end time
   //----------------------------------------------------------------
   else if (pastEnd && !g_cleanupDone)
   {
      g_buyCrossArmed  = false;
      g_sellCrossArmed = false;
      PrintFormat("Trading window closed (%02d:%02d broker time).", InpEndHour, InpEndMin);
      g_cleanupDone = true;
   }

   // Store current bid for next tick's cross detection
   g_lastBid = bid;
}
//+------------------------------------------------------------------+
