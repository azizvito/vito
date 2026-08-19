//+------------------------------------------------------------------+
//|  GTE V7 - Gold Trend Engine V7, Structure Matrix (MetaTrader 4)  |
//|                                                                  |
//|  Chart version of the engine used by GTE_V7_EA:                  |
//|    BULL / BEAR labels on the break of structure                  |
//|    supply and demand zones with a 50 percent line                |
//|    grey zones once they are mitigated                            |
//|    scalping panel with the 1/3/5/10/15/25 minute trend           |
//|                                                                  |
//|  This file only draws, it never sends an order.                  |
//+------------------------------------------------------------------+
#property copyright "GTE V7"
#property link      ""
#property version   "1.00"
#property strict
#property indicator_chart_window

enum GteZoneSource { GTE_ZONE_WICK = 0, GTE_ZONE_BODY = 1 };
enum GteLanguage   { GTE_ENGLISH   = 0, GTE_ARABIC    = 1 };

input string s1                 = "===== 1  Market Structure =====";
input int    SwingLength         = 8;      // Swing length (bars each side)
input bool   ConfirmWithClose    = true;   // Confirm the break with the close
input bool   ShiftOnly           = false;  // Only reversals (CHoCH)
input GteZoneSource ZoneSource   = GTE_ZONE_WICK; // Order block size
input int    ZoneLookback        = 100;    // Bars searched for the base candle
input int    ScanBars            = 600;    // History replayed on every new bar

input string s2                 = "===== 2  Chart Objects =====";
input bool   ShowSignals         = true;   // BULL / BEAR labels
input bool   ShowZones           = true;   // Order blocks
input bool   ShowMidLine         = true;   // 50 percent dashed line
input bool   ShowZonePrice       = true;   // Print the zone price
input bool   ShowSwingPrice      = true;   // Print the price of each swing point
input bool   KeepMitigated       = true;   // Keep broken zones in grey
input int    MaxDrawnSignals     = 25;     // Newest signals kept on the chart
input int    ZoneExtendBars      = 40;     // Extension to the right
input int    AtrPeriod           = 14;     // ATR used to place the labels
input color  BullColor           = clrSeaGreen;
input color  BearColor           = clrCrimson;
input color  BullZoneColor       = C'12,48,32';
input color  BearZoneColor       = C'62,20,24';
input color  DeadZoneColor       = C'42,42,46';
input color  SwingPriceColor     = C'150,153,163';
input color  TextColor           = clrWhite;

input string s3                 = "===== 3  Trend Panel =====";
input bool   ShowPanel           = true;
input bool   ShowPanelBackground = true;
input GteLanguage PanelLanguage  = GTE_ARABIC;
input int    PanelMinutes1       = 1;
input int    PanelMinutes2       = 3;
input int    PanelMinutes3       = 5;
input int    PanelMinutes4       = 10;
input int    PanelMinutes5       = 15;
input int    PanelMinutes6       = 25;
input int    PanelSwingLength    = 5;
input int    PanelX              = 12;
input int    PanelY              = 20;
input int    PanelFontSize       = 9;

#define GTE_MAX_SIGNALS 400
#define GTE_TF_BARS     260

string   g_prefix = "GTEv7i_";
int      g_sigShift[GTE_MAX_SIGNALS];
int      g_sigDir[GTE_MAX_SIGNALS];
bool     g_sigChoch[GTE_MAX_SIGNALS];
double   g_sigZoneTop[GTE_MAX_SIGNALS];
double   g_sigZoneBot[GTE_MAX_SIGNALS];
int      g_sigZoneShift[GTE_MAX_SIGNALS];
int      g_sigCount = 0;
int      g_trend    = 0;
datetime g_lastBar  = 0;

//+------------------------------------------------------------------+
//| Structure engine                                                 |
//+------------------------------------------------------------------+
bool IsPivotHigh(const int shift, const int length)
{
   if(shift - length < 0 || shift + length >= Bars)
      return(false);
   double value = High[shift];
   for(int step = 1; step <= length; step++)
   {
      if(High[shift + step] >= value)
         return(false);
      if(High[shift - step] >= value)
         return(false);
   }
   return(true);
}

bool IsPivotLow(const int shift, const int length)
{
   if(shift - length < 0 || shift + length >= Bars)
      return(false);
   double value = Low[shift];
   for(int step = 1; step <= length; step++)
   {
      if(Low[shift + step] <= value)
         return(false);
      if(Low[shift - step] <= value)
         return(false);
   }
   return(true);
}

int BaseCandleShift(const int shift, const int direction)
{
   int limit = (int)MathMin(ZoneLookback, Bars - shift - 2);
   for(int back = 1; back <= limit; back++)
   {
      int candle = shift + back;
      bool isBase = (direction > 0) ? (Close[candle] < Open[candle]) : (Close[candle] > Open[candle]);
      if(isBase)
         return(candle);
   }
   return(shift);
}

void ZoneOf(const int candle, double &top, double &bottom)
{
   if(ZoneSource == GTE_ZONE_WICK)
   {
      top = High[candle];
      bottom = Low[candle];
      return;
   }
   top = MathMax(Open[candle], Close[candle]);
   bottom = MathMin(Open[candle], Close[candle]);
}

void PushSignal(const int shift, const int direction, const bool choch)
{
   if(g_sigCount >= GTE_MAX_SIGNALS)
      return;
   int candle = BaseCandleShift(shift, direction);
   double top = 0.0, bottom = 0.0;
   ZoneOf(candle, top, bottom);

   g_sigShift[g_sigCount]     = shift;
   g_sigDir[g_sigCount]       = direction;
   g_sigChoch[g_sigCount]     = choch;
   g_sigZoneShift[g_sigCount] = candle;
   g_sigZoneTop[g_sigCount]   = top;
   g_sigZoneBot[g_sigCount]   = bottom;
   g_sigCount++;
}

void ScanStructure()
{
   g_sigCount = 0;
   g_trend = 0;

   int available = Bars - SwingLength - 2;
   int start = (int)MathMin(ScanBars, available);
   if(start < SwingLength * 2 + 5)
      return;

   double swingHigh = 0.0, swingLow = 0.0;
   bool haveHigh = false, haveLow = false;
   bool highTaken = true, lowTaken = true;

   for(int shift = start; shift >= 1; shift--)
   {
      int candidate = shift + SwingLength;

      if(IsPivotHigh(candidate, SwingLength))
      {
         swingHigh = High[candidate];
         haveHigh = true;
         highTaken = false;
         if(ShowSwingPrice)
            MakeText(g_prefix + "swp_h_" + IntegerToString((int)Time[candidate]),
                     Time[candidate], High[candidate] + 2 * Point,
                     DoubleToString(High[candidate], Digits), SwingPriceColor, 7, "Tahoma");
      }
      if(IsPivotLow(candidate, SwingLength))
      {
         swingLow = Low[candidate];
         haveLow = true;
         lowTaken = false;
         if(ShowSwingPrice)
            MakeText(g_prefix + "swp_l_" + IntegerToString((int)Time[candidate]),
                     Time[candidate], Low[candidate] - 2 * Point,
                     DoubleToString(Low[candidate], Digits), SwingPriceColor, 7, "Tahoma");
      }

      double sourceUp = ConfirmWithClose ? Close[shift] : High[shift];
      double sourceDown = ConfirmWithClose ? Close[shift] : Low[shift];

      bool brokeHigh = haveHigh && !highTaken && sourceUp > swingHigh;
      bool brokeLow  = haveLow  && !lowTaken  && sourceDown < swingLow;

      if(brokeHigh)
      {
         bool chochUp = (g_trend <= 0);
         bool emitUp = ShiftOnly ? chochUp : true;
         highTaken = true;
         g_trend = 1;
         if(emitUp)
            PushSignal(shift, 1, chochUp);
      }
      if(brokeLow)
      {
         bool chochDown = (g_trend >= 0);
         bool emitDown = ShiftOnly ? chochDown : true;
         lowTaken = true;
         g_trend = -1;
         if(emitDown)
            PushSignal(shift, -1, chochDown);
      }
   }
}

//+------------------------------------------------------------------+
//| Trend of any minute based timeframe                              |
//+------------------------------------------------------------------+
int NativePeriod(const int minutes)
{
   switch(minutes)
   {
      case 1:    return(PERIOD_M1);
      case 5:    return(PERIOD_M5);
      case 15:   return(PERIOD_M15);
      case 30:   return(PERIOD_M30);
      case 60:   return(PERIOD_H1);
      case 240:  return(PERIOD_H4);
      case 1440: return(PERIOD_D1);
   }
   return(0);
}

int LoadTimeframe(const int minutes, double &highs[], double &lows[], double &closes[], const int wanted)
{
   ArrayResize(highs, wanted);
   ArrayResize(lows, wanted);
   ArrayResize(closes, wanted);

   int period = NativePeriod(minutes);
   if(period > 0)
   {
      int total = (int)MathMin(wanted, iBars(Symbol(), period));
      for(int shift = 0; shift < total; shift++)
      {
         highs[shift]  = iHigh(Symbol(), period, shift);
         lows[shift]   = iLow(Symbol(), period, shift);
         closes[shift] = iClose(Symbol(), period, shift);
      }
      return(total);
   }

   int seconds = minutes * 60;
   if(seconds <= 0)
      return(0);
   int m1Bars = iBars(Symbol(), PERIOD_M1);
   if(m1Bars <= 0)
      return(0);
   int scan = (int)MathMin(m1Bars, wanted * minutes + minutes * 4);

   int count = -1;
   datetime bucket = 0;
   for(int m1 = 0; m1 < scan; m1++)
   {
      datetime stamp = iTime(Symbol(), PERIOD_M1, m1);
      if(stamp == 0)
         break;
      datetime start = (datetime)(stamp - (stamp % seconds));
      if(count < 0 || start != bucket)
      {
         count++;
         if(count >= wanted)
            return(wanted);
         bucket = start;
         highs[count]  = iHigh(Symbol(), PERIOD_M1, m1);
         lows[count]   = iLow(Symbol(), PERIOD_M1, m1);
         closes[count] = iClose(Symbol(), PERIOD_M1, m1);
      }
      else
      {
         highs[count] = MathMax(highs[count], iHigh(Symbol(), PERIOD_M1, m1));
         lows[count]  = MathMin(lows[count], iLow(Symbol(), PERIOD_M1, m1));
      }
   }
   return(count + 1);
}

bool ArrayPivotHigh(const double &values[], const int index, const int length, const int count)
{
   if(index - length < 0 || index + length >= count)
      return(false);
   double value = values[index];
   for(int step = 1; step <= length; step++)
   {
      if(values[index + step] >= value)
         return(false);
      if(values[index - step] >= value)
         return(false);
   }
   return(true);
}

bool ArrayPivotLow(const double &values[], const int index, const int length, const int count)
{
   if(index - length < 0 || index + length >= count)
      return(false);
   double value = values[index];
   for(int step = 1; step <= length; step++)
   {
      if(values[index + step] <= value)
         return(false);
      if(values[index - step] <= value)
         return(false);
   }
   return(true);
}

int TimeframeTrend(const int minutes, const int swingLength)
{
   if(minutes <= 0)
      return(0);
   double highs[], lows[], closes[];
   int count = LoadTimeframe(minutes, highs, lows, closes, GTE_TF_BARS);
   if(count < swingLength * 2 + 3)
      return(0);

   double swingHigh = 0.0, swingLow = 0.0;
   bool haveHigh = false, haveLow = false;
   int trend = 0;

   for(int index = count - 2 * swingLength - 1; index >= 1; index--)
   {
      int candidate = index + swingLength;
      if(ArrayPivotHigh(highs, candidate, swingLength, count))
      {
         swingHigh = highs[candidate];
         haveHigh = true;
      }
      if(ArrayPivotLow(lows, candidate, swingLength, count))
      {
         swingLow = lows[candidate];
         haveLow = true;
      }
      if(haveHigh && closes[index] > swingHigh)
         trend = 1;
      if(haveLow && closes[index] < swingLow)
         trend = -1;
   }
   return(trend);
}

//+------------------------------------------------------------------+
//| Chart objects                                                    |
//+------------------------------------------------------------------+
void DeleteOwnObjects(const string tag)
{
   string needle = g_prefix + tag;
   for(int index = ObjectsTotal() - 1; index >= 0; index--)
   {
      string name = ObjectName(index);
      if(StringFind(name, needle) == 0)
         ObjectDelete(name);
   }
}

void MakeText(const string name, const datetime when, const double price, const string text,
              const color clr, const int size, const string font = "Arial Black")
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, when, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectMove(0, name, 0, when, price);
}

void MakeArrow(const string name, const datetime when, const double price, const int code, const color clr)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_ARROW, 0, when, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectMove(0, name, 0, when, price);
}

void MakeZone(const string name, const datetime from, const datetime to,
              const double top, const double bottom, const color clr, const string text)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, from, top, to, bottom);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);   // MT4 fills rectangles by itself
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectMove(0, name, 0, from, top);
   ObjectMove(0, name, 1, to, bottom);
}

void MakeMidLine(const string name, const datetime from, const datetime to, const double price, const color clr)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, from, price, to, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectMove(0, name, 0, from, price);
   ObjectMove(0, name, 1, to, price);
}

bool ZoneMitigated(const int index)
{
   double top = g_sigZoneTop[index];
   double bottom = g_sigZoneBot[index];
   for(int shift = g_sigShift[index]; shift >= 1; shift--)
   {
      if(g_sigDir[index] > 0 && Close[shift] < bottom)
         return(true);
      if(g_sigDir[index] < 0 && Close[shift] > top)
         return(true);
   }
   return(false);
}

void DrawSignals()
{
   DeleteOwnObjects("sig_");
   DeleteOwnObjects("zone_");
   if(!ShowSignals && !ShowZones)
      return;

   double atr = iATR(Symbol(), 0, AtrPeriod, 1);
   if(atr <= 0)
      atr = 10 * Point;

   int drawn = 0;
   for(int index = g_sigCount - 1; index >= 0 && drawn < MaxDrawnSignals; index--)
   {
      int shift = g_sigShift[index];
      if(shift < 1 || shift >= Bars)
         continue;
      bool bullish = (g_sigDir[index] > 0);
      color mainColor = bullish ? BullColor : BearColor;
      string tail = IntegerToString(index) + "_" + IntegerToString((int)Time[shift]);

      if(ShowSignals)
      {
         double level = bullish ? Low[shift] - atr * 0.35 : High[shift] + atr * 0.35;
         MakeArrow(g_prefix + "sig_a_" + tail, Time[shift], bullish ? Low[shift] : High[shift],
                   bullish ? 233 : 234, mainColor);
         MakeText(g_prefix + "sig_t_" + tail, Time[shift], level, bullish ? "BULL" : "BEAR", mainColor, 8);
      }

      if(ShowZones)
      {
         bool dead = ZoneMitigated(index);
         if(dead && !KeepMitigated)
         {
            drawn++;
            continue;
         }
         int zoneShift = g_sigZoneShift[index];
         if(zoneShift < 0 || zoneShift >= Bars)
            zoneShift = shift;
         datetime from = Time[zoneShift];
         datetime to = (datetime)(Time[0] + ZoneExtendBars * Period() * 60);
         color zoneColor = dead ? DeadZoneColor : (bullish ? BullZoneColor : BearZoneColor);
         double middle = (g_sigZoneTop[index] + g_sigZoneBot[index]) / 2.0;
         string caption = ShowZonePrice ? DoubleToString(middle, Digits) : "";

         MakeZone(g_prefix + "zone_r_" + tail, from, to, g_sigZoneTop[index], g_sigZoneBot[index],
                  zoneColor, caption);
         if(ShowMidLine)
            MakeMidLine(g_prefix + "zone_m_" + tail, from, to, middle, dead ? DeadZoneColor : mainColor);
         if(ShowZonePrice)
            MakeText(g_prefix + "zone_p_" + tail, from, middle, caption,
                     dead ? clrSilver : mainColor, 7, "Tahoma");
      }
      drawn++;
   }
}

//+------------------------------------------------------------------+
//| Trend panel                                                      |
//+------------------------------------------------------------------+
string PanelTimeframeName(const int minutes)
{
   if(PanelLanguage == GTE_ARABIC)
      return("دقيقة " + IntegerToString(minutes));
   return(IntegerToString(minutes) + (minutes == 1 ? " Minute" : " Minutes"));
}

string TrendWord(const int trend)
{
   if(PanelLanguage == GTE_ARABIC)
      return(trend > 0 ? "صاعد" : (trend < 0 ? "هابط" : "محايد"));
   return(trend > 0 ? "Bullish" : (trend < 0 ? "Bearish" : "Neutral"));
}

void MakePanelLabel(const string name, const int x, const int y, const string text,
                    const color clr, const int size)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, "Tahoma");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void DrawPanel()
{
   if(!ShowPanel)
   {
      DeleteOwnObjects("panel_");
      return;
   }

   int minutes[6];
   minutes[0] = PanelMinutes1;
   minutes[1] = PanelMinutes2;
   minutes[2] = PanelMinutes3;
   minutes[3] = PanelMinutes4;
   minutes[4] = PanelMinutes5;
   minutes[5] = PanelMinutes6;

   int rowHeight = PanelFontSize + 8;
   string background = g_prefix + "panel_bg";
   if(ShowPanelBackground)
   {
      if(ObjectFind(0, background) < 0)
         ObjectCreate(0, background, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, background, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, background, OBJPROP_XDISTANCE, PanelX + 4);
      ObjectSetInteger(0, background, OBJPROP_YDISTANCE, PanelY - 8);
      ObjectSetInteger(0, background, OBJPROP_XSIZE, 200);
      ObjectSetInteger(0, background, OBJPROP_YSIZE, rowHeight * 8 + 8);
      ObjectSetInteger(0, background, OBJPROP_BGCOLOR, C'22,26,37');
      ObjectSetInteger(0, background, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, background, OBJPROP_COLOR, C'70,74,86');
      ObjectSetInteger(0, background, OBJPROP_BACK, false);
      ObjectSetInteger(0, background, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, background, OBJPROP_HIDDEN, true);
   }
   else if(ObjectFind(0, background) >= 0)
      ObjectDelete(background);

   string header = (PanelLanguage == GTE_ARABIC) ? "نظرة السكالبينج" : "Scalping View";
   string columnTf = (PanelLanguage == GTE_ARABIC) ? "الفريم" : "Timeframe";
   string columnTrend = (PanelLanguage == GTE_ARABIC) ? "الاتجاه" : "Trend";

   MakePanelLabel(g_prefix + "panel_h0", PanelX + 20, PanelY, header, TextColor, PanelFontSize);
   MakePanelLabel(g_prefix + "panel_h1", PanelX + 120, PanelY + rowHeight, columnTf, C'178,181,190', PanelFontSize);
   MakePanelLabel(g_prefix + "panel_h2", PanelX + 20, PanelY + rowHeight, columnTrend, C'178,181,190', PanelFontSize);

   for(int row = 0; row < 6; row++)
   {
      int trend = TimeframeTrend(minutes[row], PanelSwingLength);
      int y = PanelY + rowHeight * (row + 2);
      MakePanelLabel(g_prefix + "panel_tf" + IntegerToString(row), PanelX + 120, y,
                     PanelTimeframeName(minutes[row]), TextColor, PanelFontSize);
      MakePanelLabel(g_prefix + "panel_tr" + IntegerToString(row), PanelX + 20, y,
                     TrendWord(trend), trend > 0 ? BullColor : (trend < 0 ? BearColor : clrSilver),
                     PanelFontSize);
   }
}

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if(SwingLength < 1 || PanelSwingLength < 1)
   {
      Print("GTE V7: the swing lengths must be 1 or more");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(ZoneLookback < 1 || ScanBars < 50)
   {
      Print("GTE V7: ZoneLookback must be >= 1 and ScanBars >= 50");
      return(INIT_PARAMETERS_INCORRECT);
   }
   IndicatorShortName("GTE V7 (" + IntegerToString(SwingLength) + ")");
   g_lastBar = 0;
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   DeleteOwnObjects("");
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < SwingLength * 2 + 20)
      return(rates_total);

   if(Time[0] == g_lastBar)
      return(rates_total);
   g_lastBar = Time[0];

   DeleteOwnObjects("swp_");
   ScanStructure();
   DrawSignals();
   DrawPanel();
   return(rates_total);
}
//+------------------------------------------------------------------+
