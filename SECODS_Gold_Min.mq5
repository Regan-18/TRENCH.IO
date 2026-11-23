//+------------------------------------------------------------------+
//|  SECODS_Gold_Min.mq5                                             |
//|  XAUUSD expert advisor - minimum-lot, partial close, BE + trail  |
//|                                                                  |
//|  NOTE: This is a NEW, open-source EA. It is NOT a decompile of   |
//|  the original SECODS .ex5 (compiled files cannot be read).       |
//|  Entry logic = documented trend-pullback strategy below.         |
//|  Test on a DEMO account / Strategy Tester before going live.     |
//+------------------------------------------------------------------+
#property copyright "Open source"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- identity
input long            InpMagic            = 520001;
//--- entry logic (trend pullback)
input ENUM_TIMEFRAMES InpTrendTF          = PERIOD_H1;   // trend timeframe
input int             InpTrendEMA         = 200;         // trend EMA period
input ENUM_TIMEFRAMES InpEntryTF          = PERIOD_M5;   // entry timeframe
input int             InpFastEMA          = 21;          // entry EMA (price must be on trend side)
input int             InpRSIPeriod        = 14;
input double          InpRSIBuyLevel      = 40.0;        // buy when RSI crosses UP through this
input double          InpRSISellLevel     = 60.0;        // sell when RSI crosses DOWN through this
//--- risk / exits
input int             InpATRPeriod        = 14;
input double          InpSLATR            = 1.5;         // stop loss = ATR * x
input double          InpTPATR            = 3.0;         // take profit = ATR * x
//--- position size: ALWAYS broker minimum lot x multiplier
input int             InpLotMultiplier    = 1;           // 1 = minimum lot (e.g. 0.01). Partial close needs >= 2
//--- partial close
input bool            InpUsePartial       = true;
input double          InpPartialAtR       = 1.0;         // close part when profit = R * x
input double          InpPartialPercent   = 50.0;        // % of volume to close
input bool            InpBEAfterPartial   = true;        // move SL to break-even after partial
input bool            InpUseTrail         = true;
input double          InpTrailATR         = 1.0;         // trail distance = ATR * x (after partial/1R)
//--- filters / guards
input int             InpMaxSpreadPts     = 40;          // skip entries if spread (points) above this
input int             InpStartHour        = 7;           // server hour
input int             InpEndHour          = 20;          // server hour
input int             InpMaxTradesPerDay  = 6;
input double          InpMaxDailyLossPct  = 3.0;         // stop opening after this % of balance lost today
input int             InpSlippagePts      = 30;
input int             InpMaxOpenPos       = 1;
//--- dashboard export
input string          InpStatusFile       = "SECODS_status.json"; // written to Common\Files

CTrade   trade;
int      hTrendEMA = INVALID_HANDLE, hFastEMA = INVALID_HANDLE, hRSI = INVALID_HANDLE, hATR = INVALID_HANDLE;
datetime lastBar = 0;
string   gvPrefix;

//+------------------------------------------------------------------+
int OnInit()
{
   hTrendEMA = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hFastEMA  = iMA(_Symbol, InpEntryTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI      = iRSI(_Symbol, InpEntryTF, InpRSIPeriod, PRICE_CLOSE);
   hATR      = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   if(hTrendEMA==INVALID_HANDLE || hFastEMA==INVALID_HANDLE || hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE)
   { Print("Indicator handle error"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   gvPrefix = "SECODS_" + (string)InpMagic + "_";
   EventSetTimer(2);
   PrintFormat("SECODS_Gold_Min started on %s | min lot %.2f step %.2f", _Symbol,
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   IndicatorRelease(hTrendEMA); IndicatorRelease(hFastEMA); IndicatorRelease(hRSI); IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
bool Get(int handle, int shift, double &val)
{
   double b[1];
   if(CopyBuffer(handle, 0, shift, 1, b) != 1) return false;
   val = b[0];
   return true;
}

double TradeVolume()
{
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double v = minL * MathMax(1, InpLotMultiplier);
   v = MathFloor(v / step + 1e-9) * step;
   return NormalizeDouble(MathMin(MathMax(v, minL), maxL), 2);
}

datetime DayStart() { MqlDateTime t; TimeCurrent(t); t.hour = 0; t.min = 0; t.sec = 0; return StructToTime(t); }

// realised P/L and number of entries today for this EA
void TodayStats(double &pnl, int &entries)
{
   pnl = 0; entries = 0;
   if(!HistorySelect(DayStart(), TimeCurrent() + 60)) return;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      long e = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e == DEAL_ENTRY_IN) entries++;
      if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY)
         pnl += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
   }
}

double FloatingPnl()
{
   double p = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return p;
}

int OpenCount()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol) c++;
   }
   return c;
}

bool EntriesAllowed()
{
   MqlDateTime t; TimeCurrent(t);
   if(t.hour < InpStartHour || t.hour >= InpEndHour) return false;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPts) return false;
   if(OpenCount() >= InpMaxOpenPos) return false;
   double pnl; int n; TodayStats(pnl, n);
   if(n >= InpMaxTradesPerDay) return false;
   double dayLoss = pnl + FloatingPnl();
   if(dayLoss < 0 && MathAbs(dayLoss) >= AccountInfoDouble(ACCOUNT_BALANCE) * InpMaxDailyLossPct / 100.0) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Entry logic: H1 trend filter + M5 RSI pullback re-cross          |
//+------------------------------------------------------------------+
int Signal()   // +1 buy, -1 sell, 0 none  (uses closed bars only)
{
   double trendEma, trendEmaOld, fast, rsi1, rsi2, atr;
   if(!Get(hTrendEMA, 1, trendEma) || !Get(hTrendEMA, 4, trendEmaOld)) return 0;
   if(!Get(hFastEMA, 1, fast) || !Get(hRSI, 1, rsi1) || !Get(hRSI, 2, rsi2) || !Get(hATR, 1, atr)) return 0;
   double htfClose = iClose(_Symbol, InpTrendTF, 1);
   double close1   = iClose(_Symbol, InpEntryTF, 1);

   bool up   = htfClose > trendEma && trendEma > trendEmaOld;
   bool down = htfClose < trendEma && trendEma < trendEmaOld;

   if(up   && rsi2 < InpRSIBuyLevel  && rsi1 >= InpRSIBuyLevel  && close1 > fast) return 1;
   if(down && rsi2 > InpRSISellLevel && rsi1 <= InpRSISellLevel && close1 < fast) return -1;
   return 0;
}

void OpenTrade(int dir)
{
   double atr;
   if(!Get(hATR, 1, atr) || atr <= 0) return;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minDist = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 5) * point;
   double slD = MathMax(atr * InpSLATR, minDist);
   double tpD = MathMax(atr * InpTPATR, minDist);
   double vol = TradeVolume();

   if(dir > 0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      trade.Buy(vol, _Symbol, ask, NormalizeDouble(ask - slD, digits), NormalizeDouble(ask + tpD, digits), "SECODS buy");
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      trade.Sell(vol, _Symbol, bid, NormalizeDouble(bid + slD, digits), NormalizeDouble(bid - tpD, digits), "SECODS sell");
   }
   if(trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_PLACED)
      PrintFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Manage open positions: partial close -> break-even -> ATR trail  |
//+------------------------------------------------------------------+
void ManagePositions()
{
   double atr;
   if(!Get(hATR, 1, atr)) return;
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double stopLvl = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 2) * point;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double vol  = PositionGetDouble(POSITION_VOLUME);

      string gvR = gvPrefix + (string)ticket + "_R";
      string gvP = gvPrefix + (string)ticket + "_P";
      if(!GlobalVariableCheck(gvR))
      {
         if(sl <= 0) continue;
         GlobalVariableSet(gvR, MathAbs(open - sl));   // initial risk distance (R)
      }
      double R = GlobalVariableGet(gvR);
      bool partialDone = GlobalVariableCheck(gvP);
      double profitDist = (type == POSITION_TYPE_BUY) ? bid - open : open - ask;

      //--- 1) partial close at 1R (or whatever InpPartialAtR is)
      if(InpUsePartial && !partialDone && profitDist >= R * InpPartialAtR)
      {
         double cv = MathFloor(vol * InpPartialPercent / 100.0 / step + 1e-9) * step;
         cv = NormalizeDouble(cv, 2);
         if(cv >= minLot && (vol - cv) >= minLot - 1e-9)
         {
            if(trade.PositionClosePartial(ticket, cv, InpSlippagePts))
               PrintFormat("Partial close %.2f lots on #%I64u at %.1fR", cv, ticket, profitDist / R);
            else
               PrintFormat("Partial close failed: %s", trade.ResultRetcodeDescription());
         }
         else
            PrintFormat("#%I64u: volume %.2f too small to split (min %.2f). Raise InpLotMultiplier to >= 2. Using BE/trail only.", ticket, vol, minLot);
         GlobalVariableSet(gvP, 1);
         partialDone = true;
         if(!PositionSelectByTicket(ticket)) continue;   // refresh after partial
         vol = PositionGetDouble(POSITION_VOLUME);
         sl  = PositionGetDouble(POSITION_SL);
      }

      //--- 2) break-even after partial
      double newSL = sl;
      if(partialDone && InpBEAfterPartial)
      {
         double spreadBuf = (ask - bid) + 2 * point;
         if(type == POSITION_TYPE_BUY)  newSL = MathMax(newSL, open + spreadBuf);
         else                            newSL = (newSL == 0) ? open - spreadBuf : MathMin(newSL, open - spreadBuf);
      }

      //--- 3) ATR trail (only once past partial / 1R)
      if(InpUseTrail && (partialDone || profitDist >= R))
      {
         if(type == POSITION_TYPE_BUY)  newSL = MathMax(newSL, bid - atr * InpTrailATR);
         else                            newSL = (newSL == 0) ? ask + atr * InpTrailATR : MathMin(newSL, ask + atr * InpTrailATR);
      }

      newSL = NormalizeDouble(newSL, digits);
      bool better = (type == POSITION_TYPE_BUY) ? (newSL > sl + point) : (sl == 0 || newSL < sl - point);
      bool legal  = (type == POSITION_TYPE_BUY) ? (bid - newSL >= stopLvl) : (newSL - ask >= stopLvl);
      if(better && legal)
         trade.PositionModify(ticket, newSL, tp);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   datetime bar = iTime(_Symbol, InpEntryTF, 0);
   if(bar == lastBar) return;          // evaluate entries once per new bar
   lastBar = bar;

   if(!EntriesAllowed()) return;
   int s = Signal();
   if(s != 0) OpenTrade(s);
}

//+------------------------------------------------------------------+
//| Export a small JSON snapshot for the web dashboard (read-only)   |
//+------------------------------------------------------------------+
string Esc(string s) { StringReplace(s, "\\", "\\\\"); StringReplace(s, "\"", "\\\""); return s; }

void OnTimer()
{
   double pnl; int n; TodayStats(pnl, n);
   string j = "{";
   j += "\"updated\":" + (string)(long)TimeGMT() + ",";
   j += "\"symbol\":\"" + _Symbol + "\",";
   j += "\"currency\":\"" + AccountInfoString(ACCOUNT_CURRENCY) + "\",";
   j += "\"account\":" + (string)AccountInfoInteger(ACCOUNT_LOGIN) + ",";
   j += "\"server\":\"" + Esc(AccountInfoString(ACCOUNT_SERVER)) + "\",";
   j += "\"demo\":" + (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "true" : "false") + ",";
   j += "\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ",";
   j += "\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + ",";
   j += "\"margin\":" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2) + ",";
   j += "\"freeMargin\":" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + ",";
   j += "\"bid\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) + ",";
   j += "\"spread\":" + (string)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) + ",";
   j += "\"todayPnl\":" + DoubleToString(pnl + FloatingPnl(), 2) + ",";
   j += "\"todayTrades\":" + (string)n + ",";
   j += "\"lot\":" + DoubleToString(TradeVolume(), 2) + ",";

   j += "\"positions\":[";
   bool first = true;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(!first) j += ","; first = false;
      j += "{\"ticket\":" + (string)t + ",\"type\":\"" + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL") + "\"," +
           "\"volume\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + "," +
           "\"open\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 2) + "," +
           "\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), 2) + "," +
           "\"tp\":" + DoubleToString(PositionGetDouble(POSITION_TP), 2) + "," +
           "\"profit\":" + DoubleToString(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP), 2) + "}";
   }
   j += "],";

   j += "\"history\":[";
   first = true;
   if(HistorySelect(TimeCurrent() - 30 * 86400, TimeCurrent() + 60))
   {
      int shown = 0;
      for(int i = HistoryDealsTotal() - 1; i >= 0 && shown < 30; i--)
      {
         ulong d = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         if(!first) j += ","; first = false; shown++;
         j += "{\"time\":" + (string)(long)HistoryDealGetInteger(d, DEAL_TIME) + ",\"type\":\"" +
              (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_SELL ? "BUY" : "SELL") + "\"," +   // closing deal is opposite side
              "\"volume\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_VOLUME), 2) + "," +
              "\"price\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_PRICE), 2) + "," +
              "\"profit\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION), 2) + "}";
      }
   }
   j += "]}";

   int f = FileOpen(InpStatusFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(f != INVALID_HANDLE) { FileWriteString(f, j); FileClose(f); }
}
//+------------------------------------------------------------------+
