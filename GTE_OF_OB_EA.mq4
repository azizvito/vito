//+------------------------------------------------------------------+
//|                                              GTE_OF_OB_EA.mq4    |
//|  MT4 Expert Advisor — BULL/BEAR pivot signals + ATR TP/SL        |
//|  Inspired by GTE+OF+OB chart visuals (original MQL4 code)        |
//+------------------------------------------------------------------+
#property copyright "GTE+OF+OB Style EA"
#property version   "1.00"
#property strict

//--- Trend
input string           InpSepTrend     = "===== Trend Engine ====="; // —
input int              InpEmaFast      = 8;
input int              InpEmaSlow      = 21;
input int              InpAtrLen       = 14;
input int              InpRsiLen       = 7;
input bool             InpConfirmTrend = true;     // Require EMA/RSI alignment

//--- Signals
input string           InpSepSignal    = "===== BULL / BEAR ====="; // —
input int              InpPivotLeft    = 5;
input int              InpPivotRight   = 2;
input bool             InpUseWick      = true;      // Use wick extremes
input double           InpMinAtrMult   = 0.18;      // Min pivot ATR filter
input int              InpCooldownBars = 9;         // Min bars between signals

//--- Risk / Orders
input string           InpSepRisk      = "===== Risk Management ====="; // —
input double           InpLots         = 0.10;      // Fixed lot (if risk%=0)
input double           InpRiskPercent  = 1.0;       // Risk % of balance (0=fixed lot)
input double           InpTpAtrMult    = 1.35;      // Take Profit = ATR ×
input double           InpSlAtrMult    = 0.60;      // Stop Loss = ATR ×
input bool             InpUseFlipExit  = true;      // Close opposite on new signal
input bool             InpTradeBull    = true;
input bool             InpTradeBear    = true;
input int              InpMaxSpreadPts = 50;        // Max spread (points), 0=off
input int              InpMagic        = 770701;
input string           InpComment      = "GTE+OF+OB";
input int              InpSlippage     = 30;

//--- MTF filter (optional)
input string           InpSepMTF       = "===== MTF Filter ====="; // —
input bool             InpUseMtfFilter = false;     // Only trade with higher TF
input ENUM_TIMEFRAMES  InpMtfTf        = PERIOD_M5;
input int              InpMtfEmaFast   = 8;
input int              InpMtfEmaSlow   = 21;

//--- Visuals
input string           InpSepVis       = "===== Visuals ====="; // —
input bool             InpDrawArrows   = true;
input bool             InpDrawLabels   = true;
input bool             InpShowPanel    = true;

//--- Internals
datetime g_lastBarTime   = 0;
int      g_lastBullBar   = -999999;
int      g_lastBearBar   = -999999;
int      g_lastDir       = 0; // 1=bull, -1=bear
string   g_prefix        = "GTE_";

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPivotLeft < 1 || InpPivotRight < 1)
   {
      Print("Pivot bars must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   Comment("");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, g_prefix);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsTradeAllowed())
      return;

   // Work on new closed-bar confirmation (pivot needs right bars)
   datetime t = iTime(Symbol(), Period(), 0);
   bool newBar = (t != g_lastBarTime);
   if(newBar)
      g_lastBarTime = t;

   ManageVisualPanel();

   // Evaluate signal on new bar (confirmed pivot at shift = InpPivotRight)
   if(!newBar)
      return;

   int signal = DetectSignal(); // 1 BULL, -1 BEAR, 0 none
   if(signal == 0)
      return;

   if(InpMaxSpreadPts > 0)
   {
      int spread = (int)((Ask - Bid) / Point);
      if(spread > InpMaxSpreadPts)
      {
         Print("Spread too high: ", spread);
         return;
      }
   }

   if(InpUseMtfFilter)
   {
      int mtf = MtfTrend();
      if(signal == 1 && mtf < 0) return;
      if(signal == -1 && mtf > 0) return;
   }

   double atr = iATR(Symbol(), Period(), InpAtrLen, InpPivotRight);
   if(atr <= 0)
      return;

   if(signal == 1 && InpTradeBull)
   {
      if(InpUseFlipExit)
         CloseDirection(OP_SELL, "Close SELL on BULL");
      if(!HasOpenDirection(OP_BUY))
         OpenTrade(OP_BUY, atr);
      DrawSignal(1);
      g_lastDir = 1;
   }
   else if(signal == -1 && InpTradeBear)
   {
      if(InpUseFlipExit)
         CloseDirection(OP_BUY, "Close BUY on BEAR");
      if(!HasOpenDirection(OP_SELL))
         OpenTrade(OP_SELL, atr);
      DrawSignal(-1);
      g_lastDir = -1;
   }
}

//+------------------------------------------------------------------+
//| Signal: confirmed pivot low/high at bar shift = InpPivotRight    |
//+------------------------------------------------------------------+
int DetectSignal()
{
   int shift = InpPivotRight; // pivot center after right bars closed
   int barsNeeded = InpPivotLeft + InpPivotRight + 5;
   if(Bars < barsNeeded)
      return(0);

   double atr = iATR(Symbol(), Period(), InpAtrLen, shift);
   double rsi = iRSI(Symbol(), Period(), InpRsiLen, PRICE_CLOSE, shift);
   double emaF = iMA(Symbol(), Period(), InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, shift);
   double emaS = iMA(Symbol(), Period(), InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, shift);
   bool trendUp = (emaF > emaS);

   bool isPL = IsPivotLow(shift);
   bool isPH = IsPivotHigh(shift);

   double closeSh = iClose(Symbol(), Period(), shift);
   double plPrice = PivotPriceLow(shift);
   double phPrice = PivotPriceHigh(shift);

   bool coolBull = (Bars - g_lastBullBar) >= InpCooldownBars;
   bool coolBear = (Bars - g_lastBearBar) >= InpCooldownBars;

   bool strongBull = (atr == 0) || (MathAbs(plPrice - closeSh) >= atr * InpMinAtrMult);
   bool strongBear = (atr == 0) || (MathAbs(phPrice - closeSh) >= atr * InpMinAtrMult);

   bool bull = isPL && coolBull && strongBull &&
               (!InpConfirmTrend || trendUp || rsi < 40.0);
   bool bear = isPH && coolBear && strongBear &&
               (!InpConfirmTrend || !trendUp || rsi > 60.0);

   // Prefer single signal; if both rare, skip
   if(bull && bear)
      return(0);

   if(bull)
   {
      g_lastBullBar = Bars;
      return(1);
   }
   if(bear)
   {
      g_lastBearBar = Bars;
      return(-1);
   }
   return(0);
}

//+------------------------------------------------------------------+
bool IsPivotHigh(int shift)
{
   double c = PivotPriceHigh(shift);
   for(int i = 1; i <= InpPivotLeft; i++)
   {
      if(PivotPriceHigh(shift + i) >= c)
         return(false);
   }
   for(int r = 1; r <= InpPivotRight; r++)
   {
      if(PivotPriceHigh(shift - r) >= c)
         return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
bool IsPivotLow(int shift)
{
   double c = PivotPriceLow(shift);
   for(int i = 1; i <= InpPivotLeft; i++)
   {
      if(PivotPriceLow(shift + i) <= c)
         return(false);
   }
   for(int r = 1; r <= InpPivotRight; r++)
   {
      if(PivotPriceLow(shift - r) <= c)
         return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
double PivotPriceHigh(int shift)
{
   if(InpUseWick)
      return(iHigh(Symbol(), Period(), shift));
   return(MathMax(iOpen(Symbol(), Period(), shift), iClose(Symbol(), Period(), shift)));
}

//+------------------------------------------------------------------+
double PivotPriceLow(int shift)
{
   if(InpUseWick)
      return(iLow(Symbol(), Period(), shift));
   return(MathMin(iOpen(Symbol(), Period(), shift), iClose(Symbol(), Period(), shift)));
}

//+------------------------------------------------------------------+
int MtfTrend()
{
   double ef = iMA(Symbol(), InpMtfTf, InpMtfEmaFast, 0, MODE_EMA, PRICE_CLOSE, 0);
   double es = iMA(Symbol(), InpMtfTf, InpMtfEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 0);
   if(ef > es) return(1);
   if(ef < es) return(-1);
   return(0);
}

//+------------------------------------------------------------------+
double CalcLots(double slDistancePrice)
{
   if(InpRiskPercent <= 0.0 || slDistancePrice <= 0.0)
      return(NormalizeLots(InpLots));

   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(tickValue <= 0 || tickSize <= 0)
      return(NormalizeLots(InpLots));

   double riskMoney = AccountBalance() * InpRiskPercent / 100.0;
   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0)
      return(NormalizeLots(InpLots));

   double lots = riskMoney / lossPerLot;
   return(NormalizeLots(lots));
}

//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double step    = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   int digits = 2;
   if(step >= 0.1) digits = 1;
   if(step >= 1.0) digits = 0;
   return(NormalizeDouble(lots, digits));
}

//+------------------------------------------------------------------+
bool HasOpenDirection(int type)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic)
         continue;
      if(OrderType() == type)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
void CloseDirection(int type, string reason)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic)
         continue;
      if(OrderType() != type)
         continue;

      double price = (type == OP_BUY) ? Bid : Ask;
      bool ok = OrderClose(OrderTicket(), OrderLots(), price, InpSlippage, clrNONE);
      if(!ok)
         Print(reason, " failed: ", GetLastError());
      else
         Print(reason, " OK #", OrderTicket());
   }
}

//+------------------------------------------------------------------+
void OpenTrade(int type, double atr)
{
   double slDist = atr * InpSlAtrMult;
   double tpDist = atr * InpTpAtrMult;
   double lots   = CalcLots(slDist);

   double price, sl, tp;
   color  clr;
   string label;

   if(type == OP_BUY)
   {
      price = Ask;
      sl = price - slDist;
      tp = price + tpDist;
      clr = clrLime;
      label = "BULL";
   }
   else
   {
      price = Bid;
      sl = price + slDist;
      tp = price - tpDist;
      clr = clrRed;
      label = "BEAR";
   }

   int digits = (int)MarketInfo(Symbol(), MODE_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   price = NormalizeDouble(price, digits);

   // Respect stop level
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(type == OP_BUY)
   {
      if(price - sl < stopLevel && stopLevel > 0) sl = price - stopLevel;
      if(tp - price < stopLevel && stopLevel > 0) tp = price + stopLevel;
   }
   else
   {
      if(sl - price < stopLevel && stopLevel > 0) sl = price + stopLevel;
      if(price - tp < stopLevel && stopLevel > 0) tp = price - stopLevel;
   }

   int ticket = OrderSend(Symbol(), type, lots, price, InpSlippage, sl, tp,
                          InpComment + " " + label, InpMagic, 0, clr);
   if(ticket < 0)
      Print("OrderSend ", label, " failed: ", GetLastError(),
            " lots=", lots, " price=", price, " sl=", sl, " tp=", tp);
   else
      Print("Opened ", label, " #", ticket, " lots=", lots, " SL=", sl, " TP=", tp);
}

//+------------------------------------------------------------------+
void DrawSignal(int dir)
{
   if(!InpDrawArrows && !InpDrawLabels)
      return;

   int shift = InpPivotRight;
   datetime t = iTime(Symbol(), Period(), shift);
   string id = g_prefix + IntegerToString((int)t) + "_" + IntegerToString(dir);

   if(dir == 1)
   {
      double y = PivotPriceLow(shift);
      if(InpDrawArrows)
      {
         string an = id + "_arr";
         ObjectCreate(an, OBJ_ARROW_UP, 0, t, y);
         ObjectSet(an, OBJPROP_COLOR, clrLime);
         ObjectSet(an, OBJPROP_WIDTH, 2);
      }
      if(InpDrawLabels)
      {
         string ln = id + "_lab";
         ObjectCreate(ln, OBJ_TEXT, 0, t, y);
         ObjectSetText(ln, " BULL +1", 10, "Arial Bold", clrLime);
      }
   }
   else
   {
      double y = PivotPriceHigh(shift);
      if(InpDrawArrows)
      {
         string an = id + "_arr";
         ObjectCreate(an, OBJ_ARROW_DOWN, 0, t, y);
         ObjectSet(an, OBJPROP_COLOR, clrRed);
         ObjectSet(an, OBJPROP_WIDTH, 2);
      }
      if(InpDrawLabels)
      {
         string ln = id + "_lab";
         ObjectCreate(ln, OBJ_TEXT, 0, t, y);
         ObjectSetText(ln, " BEAR -1", 10, "Arial Bold", clrRed);
      }
   }
}

//+------------------------------------------------------------------+
void ManageVisualPanel()
{
   if(!InpShowPanel)
      return;

   double emaF = iMA(Symbol(), Period(), InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaS = iMA(Symbol(), Period(), InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 0);
   double atr  = iATR(Symbol(), Period(), InpAtrLen, 0);
   double rsi  = iRSI(Symbol(), Period(), InpRsiLen, PRICE_CLOSE, 0);
   string trend = (emaF > emaS) ? "BULLISH" : "BEARISH";
   int buys = CountOrders(OP_BUY);
   int sells = CountOrders(OP_SELL);

   string txt =
      "GTE+OF+OB EA\n" +
      "Trend: " + trend + "\n" +
      "RSI(" + IntegerToString(InpRsiLen) + "): " + DoubleToStr(rsi, 1) + "\n" +
      "ATR: " + DoubleToStr(atr, Digits) + "\n" +
      "Open BUY: " + IntegerToString(buys) + " | SELL: " + IntegerToString(sells) + "\n" +
      "Last signal: " + (g_lastDir == 1 ? "BULL" : g_lastDir == -1 ? "BEAR" : "-");
   Comment(txt);
}

//+------------------------------------------------------------------+
int CountOrders(int type)
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagic && OrderType() == type)
         n++;
   }
   return(n);
}

//+------------------------------------------------------------------+
