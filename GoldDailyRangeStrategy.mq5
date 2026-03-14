//+------------------------------------------------------------------+
//|                   XAUUSD Daily Range Strategy                     |
//|                     Pepperstone MT5 Platform                      |
//|                                                                  |
//|  Logic:                                                           |
//|  - At 5pm NY (Pepperstone daily candle close), record prev        |
//|    candle High/Low and begin observation window.                  |
//|  - During observation, if price breaches High → skip Buy Stop.    |
//|    If price breaches Low → skip Sell Stop.                        |
//|  - At trading window open, place remaining pending orders.        |
//|  - If one order fills, cancel the other immediately.              |
//|  - At end time, delete any untriggered pending orders.            |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Daily Range Strategy"
#property version   "1.00"
#property description "Places Buy/Sell Stops at previous day High/Low (Pepperstone, UTC+2)"

#include <Trade\Trade.mqh>

//=== Inputs =========================================================

input group "== Trading Hours (UTC+2 Broker Server Time) =="
input int    InpTueFriStartHour = 1;        // Tue-Fri Start Hour  (01:00 = 6pm NY)
input int    InpTueFriStartMin  = 0;        // Tue-Fri Start Minute
input int    InpMonStartHour    = 2;        // Monday Start Hour   (02:00 = 7pm NY)
input int    InpMonStartMin     = 0;        // Monday Start Minute
input int    InpEndHour         = 19;       // End Hour - all days (19:00 = 12pm NY)
input int    InpEndMin          = 0;        // End Minute

input group "== Strategy Parameters =="
input double InpRangePercent    = 10.0;     // SL: % of previous candle range
input double InpRiskReward      = 1.0;      // TP: Risk-to-Reward ratio
input double InpRiskPercent     = 1.0;      // Risk: % of account balance per trade

input group "== EA Settings =="
input long   InpMagicNumber     = 20240101; // EA Magic Number

//=== Globals ========================================================

CTrade trade;

// Previous candle reference
double g_prevHigh = 0.0;
double g_prevLow  = 0.0;
double g_slDist   = 0.0;   // SL distance in price units
double g_tpDist   = 0.0;   // TP distance in price units

// Pending order tickets (0 = not placed / already gone)
ulong g_buyTicket  = 0;
ulong g_sellTicket = 0;

// Session state
bool g_buyBreached   = false;  // High breached during observation → skip Buy
bool g_sellBreached  = false;  // Low  breached during observation → skip Sell
bool g_ordersPlaced  = false;  // Orders have been placed this session
bool g_cleanupDone   = false;  // EOD cleanup has run
bool g_sessionReady  = false;  // Valid session data loaded

// Day tracker — server day integer, resets on each Pepperstone daily candle
int g_lastServerDay = -1;

//+------------------------------------------------------------------+
//| Return current broker server time (UTC+2) as MqlDateTime         |
//+------------------------------------------------------------------+
MqlDateTime GetSrvDateTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt;
}

// Time comparison helpers (broker server time)
bool SrvTimeGE(int h, int m, const MqlDateTime &dt) { return dt.hour > h || (dt.hour == h && dt.min >= m); }
bool SrvTimeLT(int h, int m, const MqlDateTime &dt) { return dt.hour < h || (dt.hour == h && dt.min <  m); }

//+------------------------------------------------------------------+
//| Calculate lot size so that SL distance = InpRiskPercent of        |
//| account balance.                                                  |
//+------------------------------------------------------------------+
double CalcLots(double slDist)
{
   if (slDist <= 0.0) return 0.0;

   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * InpRiskPercent / 100.0;
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if (tickSz <= 0.0 || tickVal <= 0.0) return 0.0;

   // Dollar value per 1 lot per 1 price unit of movement
   double valPerUnit = tickVal / tickSz;
   double lots       = riskAmt / (slDist * valPerUnit);

   // Normalise to broker lot constraints
   double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   return MathMax(minL, MathMin(maxL, lots));
}

//+------------------------------------------------------------------+
//| Cancel a pending order and zero its tracking variable             |
//+------------------------------------------------------------------+
void CancelOrder(ulong &ticket, const string tag)
{
   if (ticket == 0) return;
   if (OrderSelect(ticket))
   {
      if (trade.OrderDelete(ticket))
         PrintFormat("[%s] Cancelled order #%I64u.", tag, ticket);
      else
         PrintFormat("[%s] Failed to cancel #%I64u. Err=%d", tag, ticket, GetLastError());
   }
   ticket = 0;
}

//+------------------------------------------------------------------+
//| Load prev D1 candle (index 1) High/Low and compute SL/TP         |
//+------------------------------------------------------------------+
bool LoadSessionData()
{
   // Allow a few retries in case the bar hasn't fully updated yet
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
//| Scan for existing EA orders (for restart recovery)                |
//+------------------------------------------------------------------+
void ScanExistingOrders()
{
   for (int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if (!OrderSelect(ticket))                                   continue;
      if (OrderGetInteger(ORDER_MAGIC)  != InpMagicNumber)        continue;
      if (OrderGetString(ORDER_SYMBOL)  != _Symbol)               continue;

      long type = OrderGetInteger(ORDER_TYPE);
      if      (type == ORDER_TYPE_BUY_STOP)  { g_buyTicket  = ticket; g_ordersPlaced = true; }
      else if (type == ORDER_TYPE_SELL_STOP) { g_sellTicket = ticket; g_ordersPlaced = true; }
   }
}

//+------------------------------------------------------------------+
//| Reset all per-session state and prepare a new session             |
//+------------------------------------------------------------------+
void NewSession(int serverDOW)
{
   // Cancel any leftover orders from the previous session
   CancelOrder(g_buyTicket,  "Buy-Reset");
   CancelOrder(g_sellTicket, "Sell-Reset");

   g_prevHigh     = 0.0;  g_prevLow    = 0.0;
   g_slDist       = 0.0;  g_tpDist     = 0.0;
   g_buyBreached  = false; g_sellBreached = false;
   g_ordersPlaced = false; g_cleanupDone  = false;
   g_sessionReady = false;

   // No trading on weekends
   if (serverDOW == 0 || serverDOW == 6) return;

   if (!LoadSessionData())
   {
      Print("Session setup failed — invalid previous candle data.");
      return;
   }

   g_sessionReady = true;
   PrintFormat("Session ready [DOW=%d] | Prev High=%.2f | Prev Low=%.2f | SL=%.2f | TP=%.2f",
               serverDOW, g_prevHigh, g_prevLow, g_slDist, g_tpDist);
}

//+------------------------------------------------------------------+
//| Place Buy Stop and/or Sell Stop (honouring observation breaches)  |
//+------------------------------------------------------------------+
void PlaceOrders()
{
   // If market is not fully open yet (e.g. rollover break), retry on next tick
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if (tradeMode != SYMBOL_TRADE_MODE_FULL)
   {
      Print("Market not ready (", EnumToString(tradeMode), "). Retrying next tick.");
      return; // g_ordersPlaced stays false — will retry
   }

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double lots   = CalcLots(g_slDist);

   if (lots <= 0.0)
   {
      Print("Lot calculation failed — orders not placed.");
      g_ordersPlaced = true;
      return;
   }

   // --- Buy Stop ---
   if (!g_buyBreached && g_buyTicket == 0)
   {
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double entry = NormalizeDouble(g_prevHigh,            digits);
      double sl    = NormalizeDouble(g_prevHigh - g_slDist, digits);
      double tp    = NormalizeDouble(g_prevHigh + g_tpDist, digits);

      if (entry > ask)
      {
         if (trade.BuyStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "GS_Buy"))
         {
            g_buyTicket = trade.ResultOrder();
            PrintFormat("Buy Stop placed  | Entry=%.2f | SL=%.2f | TP=%.2f | Lots=%.2f",
                        entry, sl, tp, lots);
         }
         else PrintFormat("Buy Stop FAILED. Err=%d", GetLastError());
      }
      else
      {
         PrintFormat("Buy Stop skipped — Ask (%.2f) already >= High (%.2f).", ask, entry);
         g_buyBreached = true;
      }
   }

   // --- Sell Stop ---
   if (!g_sellBreached && g_sellTicket == 0)
   {
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double entry = NormalizeDouble(g_prevLow,            digits);
      double sl    = NormalizeDouble(g_prevLow + g_slDist, digits);
      double tp    = NormalizeDouble(g_prevLow - g_tpDist, digits);

      if (entry < bid)
      {
         if (trade.SellStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "GS_Sell"))
         {
            g_sellTicket = trade.ResultOrder();
            PrintFormat("Sell Stop placed | Entry=%.2f | SL=%.2f | TP=%.2f | Lots=%.2f",
                        entry, sl, tp, lots);
         }
         else PrintFormat("Sell Stop FAILED. Err=%d", GetLastError());
      }
      else
      {
         PrintFormat("Sell Stop skipped — Bid (%.2f) already <= Low (%.2f).", bid, entry);
         g_sellBreached = true;
      }
   }

   g_ordersPlaced = true;
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   // Initialise day tracker
   MqlDateTime srvDT;
   TimeToStruct(TimeCurrent(), srvDT);
   g_lastServerDay = srvDT.day;

   // Attempt to resume a session if EA starts mid-day on a weekday
   if (srvDT.day_of_week >= 1 && srvDT.day_of_week <= 5)
   {
      if (LoadSessionData())
      {
         g_sessionReady = true;

         // Restore any pending orders this EA already placed
         ScanExistingOrders();

         // Do a quick price breach check so we don't place orders in a direction already hit.
         // Observation always starts at 00:00 server time (candle open), so any mid-day
         // start is already within or past the observation window.
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if (ask >= g_prevHigh) { g_buyBreached  = true; Print("Init: High already breached."); }
            if (bid <= g_prevLow)  { g_sellBreached = true; Print("Init: Low already breached.");  }
         }

         // If past end time, mark cleanup done so we don't re-delete anything
         if (SrvTimeGE(InpEndHour, InpEndMin, srvDT))
            g_cleanupDone = true;

         PrintFormat("EA resumed mid-session [DOW=%d] | High=%.2f | Low=%.2f | OrdersPlaced=%s",
                     srvDT.day_of_week, g_prevHigh, g_prevLow,
                     g_ordersPlaced ? "Yes" : "No");
      }
   }

   Print("Gold Strategy EA initialised. Magic=", InpMagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA stopped. Reason=", reason);
}

//+------------------------------------------------------------------+
//| OnTick — Main state machine                                       |
//|                                                                  |
//| Phases (all times in UTC+2 broker server time):                  |
//|  [00:00 – StartTime]  Observation  — track price breaches        |
//|  [StartTime – EndTime] Trading      — manage pending orders       |
//|  [EndTime+]           Cleanup       — delete untriggered orders   |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Detect Pepperstone daily candle rollover (server midnight = 00:00 UTC+2)
   MqlDateTime srvDT;
   TimeToStruct(TimeCurrent(), srvDT);

   if (srvDT.day != g_lastServerDay)
   {
      g_lastServerDay = srvDT.day;
      NewSession(srvDT.day_of_week);
   }

   // Skip weekends and sessions with no valid data
   if (!g_sessionReady || srvDT.day_of_week == 0 || srvDT.day_of_week == 6)
      return;

   //--- Resolve timing parameters for today
   bool isMonday   = (srvDT.day_of_week == 1);
   int  sH         = isMonday ? InpMonStartHour : InpTueFriStartHour;
   int  sM         = isMonday ? InpMonStartMin  : InpTueFriStartMin;

   // Observation runs from 00:00 (candle open) up to the trading start time
   bool inObs      = SrvTimeLT(sH, sM,                        srvDT);
   bool inTrading  = SrvTimeGE(sH, sM,         srvDT) && SrvTimeLT(InpEndHour, InpEndMin, srvDT);
   bool pastEnd    = SrvTimeGE(InpEndHour, InpEndMin, srvDT);

   //----------------------------------------------------------------
   // Phase 1 — Observation window: track price vs prev High/Low
   //----------------------------------------------------------------
   if (inObs)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if (!g_buyBreached  && ask >= g_prevHigh)
      {
         g_buyBreached = true;
         PrintFormat("Observation: Ask %.2f >= High %.2f — Buy Stop will NOT be placed.", ask, g_prevHigh);
      }
      if (!g_sellBreached && bid <= g_prevLow)
      {
         g_sellBreached = true;
         PrintFormat("Observation: Bid %.2f <= Low %.2f — Sell Stop will NOT be placed.", bid, g_prevLow);
      }
      return;
   }

   //----------------------------------------------------------------
   // Phase 2 — Place orders at trading window open
   //----------------------------------------------------------------
   if (inTrading && !g_ordersPlaced)
      PlaceOrders();

   //----------------------------------------------------------------
   // Phase 3 — EOD cleanup: delete untriggered pending orders
   //----------------------------------------------------------------
   if (pastEnd && !g_cleanupDone)
   {
      PrintFormat("Trading window closed (%02d:%02d UTC+2). Removing pending orders.", InpEndHour, InpEndMin);
      CancelOrder(g_buyTicket,  "Buy-EOD");
      CancelOrder(g_sellTicket, "Sell-EOD");
      g_cleanupDone = true;
   }
}

//+------------------------------------------------------------------+
//| OnTradeTransaction — react instantly when a pending order fills   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   // We only care about new deals (pending order → position)
   if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if (!HistoryDealSelect(trans.deal))            return;

   // Verify it belongs to this EA on this symbol
   if (HistoryDealGetInteger(trans.deal, DEAL_MAGIC)  != InpMagicNumber) return;
   if (HistoryDealGetString (trans.deal, DEAL_SYMBOL) != _Symbol)        return;

   // Only care about position-opening deals (entry)
   if (HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_IN)   return;

   // The order ticket that triggered this deal
   ulong fromOrder = (ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER);

   if (fromOrder == g_buyTicket && g_buyTicket != 0)
   {
      PrintFormat("Buy Stop #%I64u filled — cancelling Sell Stop.", g_buyTicket);
      g_buyTicket = 0;  // Now a position, no longer a pending order
      CancelOrder(g_sellTicket, "Sell-Opposite");
   }
   else if (fromOrder == g_sellTicket && g_sellTicket != 0)
   {
      PrintFormat("Sell Stop #%I64u filled — cancelling Buy Stop.", g_sellTicket);
      g_sellTicket = 0;
      CancelOrder(g_buyTicket, "Buy-Opposite");
   }
}
//+------------------------------------------------------------------+
