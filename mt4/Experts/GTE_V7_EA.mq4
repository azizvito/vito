//+------------------------------------------------------------------+
//|  GTE V7 EA  -  Gold Trend Engine V7 for MetaTrader 4             |
//|                                                                  |
//|  Same engine as the Pine Script indicator:                       |
//|    swing pivots  ->  break of structure / CHoCH  ->  BULL / BEAR  |
//|    the last opposite candle before the impulse is the order block |
//|    stop behind the order block (or ATR), target as an R multiple  |
//|    optional multi timeframe filter, 1/3/5/10/15/25 minute panel   |
//|                                                                  |
//|  The EA draws the signals, the zones and the trend panel, and it  |
//|  executes the trades.                                            |
//+------------------------------------------------------------------+
#property copyright "GTE V7"
#property link      ""
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
enum GteZoneSource { GTE_ZONE_WICK = 0, GTE_ZONE_BODY = 1 };
enum GteStopMode   { GTE_STOP_ZONE = 0, GTE_STOP_ATR  = 1 };
enum GteLanguage   { GTE_ENGLISH   = 0, GTE_ARABIC    = 1 };

input string s1                 = "===== 1  Market Structure =====";
input int    SwingLength         = 8;      // Swing length (bars each side)
input bool   ConfirmWithClose    = true;   // Confirm the break with the close
input bool   ShiftOnly           = true;   // Trade reversals only (CHoCH)
input GteZoneSource ZoneSource   = GTE_ZONE_WICK; // Order block size
input int    ZoneLookback        = 100;    // Bars searched for the base candle
input int    ScanBars            = 600;    // History replayed on every new bar

input string s2                 = "===== 2  Trade Management =====";
input bool   TradeEnabled        = true;   // false = draw only, no orders
input GteStopMode StopMode       = GTE_STOP_ZONE; // Stop loss source
input double StopBufferPoints    = 20;     // Extra points behind the zone
input int    AtrPeriod           = 14;     // ATR period
input double AtrMultiplier       = 1.5;    // ATR stop distance
input double RewardRatio         = 2.0;    // Take profit as an R multiple
input double BreakEvenAtR        = 1.0;    // Move the stop to entry at this R (0 = off)
input double RiskPercent         = 0.5;    // Risk per trade, percent of the balance
input double FixedLot            = 0;      // > 0 uses this lot and ignores the risk
input bool   CloseOnOpposite     = true;   // Close on the opposite signal
input int    MaxSpreadPoints     = 80;     // Skip the trade above this spread
input int    SlippagePoints      = 30;     // Allowed slippage
input int    MagicNumber         = 770007; // Order id of this EA
input string OrderPrefix         = "GTE V7"; // Order comment prefix

input string s3                 = "===== 3  Filters =====";
input bool   UseMtfFilter        = false;  // Require the fast timeframes to agree
input int    MtfMinutes1         = 1;      // Filter timeframe 1 (minutes)
input int    MtfMinutes2         = 3;      // Filter timeframe 2 (minutes)
input int    MtfMinutes3         = 5;      // Filter timeframe 3 (minutes)
input int    MtfSwingLength      = 5;      // Swing length inside each timeframe
input bool   UseSession          = false;  // Trade only inside a time window
input string SessionStart        = "03:00"; // Session start (server time)
input string SessionEnd          = "21:00"; // Session end (server time)
input int    MaxTradesPerDay     = 0;      // 0 = unlimited
input bool   OnlyOnePosition     = true;   // One position at a time

input string s4                 = "===== 4  Chart Objects =====";
input bool   ShowSignals         = true;   // BULL / BEAR labels
input bool   ShowZones           = true;   // Order blocks
input bool   ShowMidLine         = true;   // 50 percent dashed line
input bool   ShowZonePrice       = true;   // Print the zone price
input bool   KeepMitigated       = true;   // Keep broken zones in grey
input int    MaxDrawnSignals     = 25;     // Newest signals kept on the chart
input int    ZoneExtendBars      = 40;     // Extension to the right
input color  BullColor           = clrSeaGreen;
input color  BearColor           = clrCrimson;
input color  BullZoneColor       = C'12,48,32';
input color  BearZoneColor       = C'62,20,24';
input color  DeadZoneColor       = C'42,42,46';
input color  TextColor           = clrWhite;

input string s5                 = "===== 5  Trend Panel =====";
input bool   ShowPanel           = true;   // Scalping view panel
input bool   ShowPanelBackground = true;   // Dark box behind the panel
input GteLanguage PanelLanguage  = GTE_ARABIC;
input int    PanelMinutes1       = 1;
input int    PanelMinutes2       = 3;
input int    PanelMinutes3       = 5;
input int    PanelMinutes4       = 10;
input int    PanelMinutes5       = 15;
input int    PanelMinutes6       = 25;
input int    PanelSwingLength    = 5;
input int    PanelX              = 12;     // Distance from the right border
input int    PanelY              = 20;     // Distance from the top border
input int    PanelFontSize       = 9;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
#define GTE_MAX_SIGNALS 400
#define GTE_TF_BARS     260

string   g_prefix     = "GTEv7_";
int      g_sigShift[GTE_MAX_SIGNALS];
int      g_sigDir[GTE_MAX_SIGNALS];
bool     g_sigChoch[GTE_MAX_SIGNALS];
double   g_sigZoneTop[GTE_MAX_SIGNALS];
double   g_sigZoneBot[GTE_MAX_SIGNALS];
int      g_sigZoneShift[GTE_MAX_SIGNALS];
double   g_sigSwing[GTE_MAX_SIGNALS];
int      g_sigCount   = 0;
int      g_trend      = 0;

datetime g_handledSignal = 0;
datetime g_lastBarTime   = 0;
int      g_tradesToday   = 0;
int      g_tradeDay      = -1;
string   g_stateKey      = "";

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
double PointsToPrice(const double points)
{
   return(points * Point);
}

double MinStopDistance()
{
   double level = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double frozen = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
   if(frozen > level)
      level = frozen;
   if(level <= 0)
      level = 2 * Point;
   return(level);
}

double SpreadPoints()
{
   return((Ask - Bid) / Point);
}

int MinutesOfDay(const datetime moment)
{
   return(TimeHour(moment) * 60 + TimeMinute(moment));
}

int ParseClock(const string text)
{
   int separator = StringFind(text, ":");
   if(separator < 0)
      return(-1);
   int hours = (int)StringToInteger(StringSubstr(text, 0, separator));
   int minutes = (int)StringToInteger(StringSubstr(text, separator + 1));
   if(hours < 0 || hours > 24 || minutes < 0 || minutes > 59)
      return(-1);
   return((hours % 24) * 60 + minutes);
}

bool InsideSession()
{
   if(!UseSession)
      return(true);
   int start = ParseClock(SessionStart);
   int end   = ParseClock(SessionEnd);
   if(start < 0 || end < 0)
      return(true);
   int now = MinutesOfDay(TimeCurrent());
   if(start <= end)
      return(now >= start && now < end);
   return(now >= start || now < end);   // window crossing midnight
}

void ResetDailyCounter()
{
   int today = TimeDayOfYear(TimeCurrent());
   if(today != g_tradeDay)
   {
      g_tradeDay = today;
      g_tradesToday = 0;
   }
}

//+------------------------------------------------------------------+
//| Structure engine on the chart timeframe                          |
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

// the last opposite candle before the impulse becomes the order block
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

void PushSignal(const int shift, const int direction, const bool choch, const double swing)
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
   g_sigSwing[g_sigCount]     = swing;
   g_sigCount++;
}

// replays the history exactly like the Pine script does
void ScanStructure()
{
   g_sigCount = 0;
   g_trend = 0;

   int available = Bars - SwingLength - 2;
   int start = (int)MathMin(ScanBars, available);
   if(start < SwingLength * 2 + 5)
      return;

   double swingHigh = 0.0, swingLow = 0.0;
   bool   haveHigh = false, haveLow = false;
   bool   highTaken = true, lowTaken = true;

   for(int shift = start; shift >= 1; shift--)
   {
      int candidate = shift + SwingLength;      // the pivot confirmed on this bar

      if(IsPivotHigh(candidate, SwingLength))
      {
         swingHigh = High[candidate];
         haveHigh = true;
         highTaken = false;
      }
      if(IsPivotLow(candidate, SwingLength))
      {
         swingLow = Low[candidate];
         haveLow = true;
         lowTaken = false;
      }

      double sourceUp = ConfirmWithClose ? Close[shift] : High[shift];
      double sourceDown = ConfirmWithClose ? Close[shift] : Low[shift];

      bool brokeHigh = haveHigh && !highTaken && sourceUp > swingHigh;
      bool brokeLow  = haveLow  && !lowTaken  && sourceDown < swingLow;

      if(brokeHigh)
      {
         bool choch = (g_trend <= 0);
         bool emit = ShiftOnly ? choch : true;
         highTaken = true;
         g_trend = 1;
         if(emit)
            PushSignal(shift, 1, choch, haveLow ? swingLow : Low[shift]);
      }

      if(brokeLow)
      {
         bool choch = (g_trend >= 0);
         bool emit = ShiftOnly ? choch : true;
         lowTaken = true;
         g_trend = -1;
         if(emit)
            PushSignal(shift, -1, choch, haveHigh ? swingHigh : High[shift]);
      }
   }
}

//+------------------------------------------------------------------+
//| Trend of any minute based timeframe (3, 10 and 25 included)      |
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

// fills highs/lows/closes with the newest bars of a timeframe, index 0 = newest
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

   // custom period: aggregate the M1 series into buckets of "minutes"
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
         closes[count] = iClose(Symbol(), PERIOD_M1, m1);   // newest M1 closes the bucket
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

// 1 bullish, -1 bearish, 0 undecided
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

bool MtfAgrees(const int direction)
{
   if(!UseMtfFilter)
      return(true);
   int one = TimeframeTrend(MtfMinutes1, MtfSwingLength);
   int two = TimeframeTrend(MtfMinutes2, MtfSwingLength);
   int three = TimeframeTrend(MtfMinutes3, MtfSwingLength);
   if(direction > 0)
      return(one > 0 && two > 0 && three > 0);
   return(one < 0 && two < 0 && three < 0);
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

// a zone dies when price closes through it, exactly like the indicator
bool ZoneMitigated(const int index)
{
   double top = g_sigZoneTop[index];
   double bottom = g_sigZoneBot[index];
   int from = g_sigShift[index];
   for(int shift = from; shift >= 1; shift--)
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
         datetime to = Time[0] + (datetime)(ZoneExtendBars * Period() * 60);
         color zoneColor = dead ? DeadZoneColor : (bullish ? BullZoneColor : BearZoneColor);
         double middle = (g_sigZoneTop[index] + g_sigZoneBot[index]) / 2.0;
         string caption = ShowZonePrice ? DoubleToString(middle, Digits) : "";

         MakeZone(g_prefix + "zone_r_" + tail, from, to, g_sigZoneTop[index], g_sigZoneBot[index],
                  zoneColor, caption);
         if(ShowMidLine)
            MakeMidLine(g_prefix + "zone_m_" + tail, from, to, middle,
                        dead ? DeadZoneColor : mainColor);
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
//| Orders                                                           |
//+------------------------------------------------------------------+
int CountOwnPositions(int &direction)
{
   int total = 0;
   direction = 0;
   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      if(!OrderSelect(index, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber)
         continue;
      if(OrderType() == OP_BUY)
      {
         total++;
         direction = 1;
      }
      else if(OrderType() == OP_SELL)
      {
         total++;
         direction = -1;
      }
   }
   return(total);
}

bool CloseOwnPositions(const int onlyDirection)
{
   bool closedAny = false;
   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      if(!OrderSelect(index, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber)
         continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;
      if(onlyDirection > 0 && type != OP_BUY)
         continue;
      if(onlyDirection < 0 && type != OP_SELL)
         continue;

      for(int attempt = 0; attempt < 3; attempt++)
      {
         RefreshRates();
         double price = (type == OP_BUY) ? Bid : Ask;
         if(OrderClose(OrderTicket(), OrderLots(), NormalizeDouble(price, Digits), SlippagePoints, clrOrange))
         {
            closedAny = true;
            break;
         }
         int error = GetLastError();
         Print(OrderPrefix, " close failed, error ", error);
         Sleep(400);
      }
   }
   return(closedAny);
}

double NormalizeLot(double lot)
{
   double minimum = MarketInfo(Symbol(), MODE_MINLOT);
   double maximum = MarketInfo(Symbol(), MODE_MAXLOT);
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0)
      step = 0.01;
   if(minimum <= 0)
      minimum = step;

   lot = MathFloor(lot / step + 0.0000001) * step;
   if(lot > maximum)
      lot = maximum;
   if(lot < minimum)
      return(0.0);

   int decimals = 2;
   if(step >= 1.0)
      decimals = 0;
   else if(step >= 0.1)
      decimals = 1;
   return(NormalizeDouble(lot, decimals));
}

double LotForRisk(const double stopDistance)
{
   if(FixedLot > 0)
      return(NormalizeLot(FixedLot));
   if(stopDistance <= 0 || RiskPercent <= 0)
      return(0.0);

   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(tickSize <= 0)
      tickSize = Point;
   if(tickValue <= 0)
      return(0.0);

   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0)
      return(0.0);

   double money = AccountBalance() * RiskPercent / 100.0;
   double lot = NormalizeLot(money / lossPerLot);

   // shrink until the margin is enough
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0)
      step = 0.01;
   int guard = 0;
   while(lot > 0 && AccountFreeMarginCheck(Symbol(), OP_BUY, lot) <= 0 && guard < 100)
   {
      lot = NormalizeLot(lot - step);
      guard++;
   }
   return(lot);
}

int SendMarketOrder(const int direction, const double lot, double stop, double target, const string comment)
{
   int type = (direction > 0) ? OP_BUY : OP_SELL;
   color arrow = (direction > 0) ? clrDodgerBlue : clrRed;

   for(int attempt = 0; attempt < 3; attempt++)
   {
      RefreshRates();
      double price = (direction > 0) ? Ask : Bid;
      int ticket = OrderSend(Symbol(), type, lot, NormalizeDouble(price, Digits), SlippagePoints,
                            NormalizeDouble(stop, Digits), NormalizeDouble(target, Digits),
                            comment, MagicNumber, 0, arrow);
      if(ticket > 0)
         return(ticket);

      int error = GetLastError();
      Print(OrderPrefix, " OrderSend failed, error ", error);

      if(error == 130 || error == 129)   // invalid stops or price, try naked then modify
      {
         RefreshRates();
         price = (direction > 0) ? Ask : Bid;
         ticket = OrderSend(Symbol(), type, lot, NormalizeDouble(price, Digits), SlippagePoints,
                            0, 0, comment, MagicNumber, 0, arrow);
         if(ticket > 0)
         {
            if(OrderSelect(ticket, SELECT_BY_TICKET))
            {
               if(!OrderModify(ticket, OrderOpenPrice(), NormalizeDouble(stop, Digits),
                               NormalizeDouble(target, Digits), 0, arrow))
                  Print(OrderPrefix, " OrderModify after naked entry failed, error ", GetLastError());
            }
            return(ticket);
         }
      }
      if(error == 134 || error == 148 || error == 4109 || error == 4110)
         return(-1);
      Sleep(500);
   }
   return(-1);
}

void ManageBreakEven()
{
   if(BreakEvenAtR <= 0)
      return;

   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      if(!OrderSelect(index, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber)
         continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;

      double entry = OrderOpenPrice();
      double stop = OrderStopLoss();
      double target = OrderTakeProfit();
      if(stop <= 0 || target <= 0)
         continue;

      // the original risk is rebuilt from the target, the stop may already have moved
      double risk = MathAbs(target - entry) / RewardRatio;
      if(risk <= 0)
         continue;

      RefreshRates();
      if(type == OP_BUY)
      {
         if(stop >= entry - Point)
            continue;                                   // already at break even or better
         if(Bid < entry + risk * BreakEvenAtR)
            continue;
         double wanted = entry;
         if(Bid - wanted < MinStopDistance())
            continue;
         if(!OrderModify(OrderTicket(), entry, NormalizeDouble(wanted, Digits), target, 0, clrAqua))
            Print(OrderPrefix, " break even failed, error ", GetLastError());
      }
      else
      {
         if(stop <= entry + Point)
            continue;
         if(Ask > entry - risk * BreakEvenAtR)
            continue;
         double wantedShort = entry;
         if(wantedShort - Ask < MinStopDistance())
            continue;
         if(!OrderModify(OrderTicket(), entry, NormalizeDouble(wantedShort, Digits), target, 0, clrAqua))
            Print(OrderPrefix, " break even failed, error ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Trading                                                          |
//+------------------------------------------------------------------+
void BuildLevels(const int direction, const int signalIndex, double &entry, double &stop, double &target)
{
   RefreshRates();
   entry = (direction > 0) ? Ask : Bid;

   double buffer = PointsToPrice(StopBufferPoints);
   double atr = iATR(Symbol(), 0, AtrPeriod, 1);
   if(atr <= 0)
      atr = 10 * Point;

   if(StopMode == GTE_STOP_ATR)
      stop = (direction > 0) ? entry - atr * AtrMultiplier : entry + atr * AtrMultiplier;
   else
   {
      if(direction > 0)
         stop = g_sigZoneBot[signalIndex] - buffer;
      else
         stop = g_sigZoneTop[signalIndex] + buffer;
   }

   double minimum = MinStopDistance();
   if(direction > 0)
   {
      if(entry - stop < minimum)
         stop = entry - minimum;
   }
   else
   {
      if(stop - entry < minimum)
         stop = entry + minimum;
   }

   double risk = MathAbs(entry - stop);
   target = (direction > 0) ? entry + risk * RewardRatio : entry - risk * RewardRatio;

   if(direction > 0 && target - entry < minimum)
      target = entry + minimum;
   if(direction < 0 && entry - target < minimum)
      target = entry - minimum;
}

void TryTrade()
{
   if(!TradeEnabled || g_sigCount <= 0)
      return;

   int newest = g_sigCount - 1;
   if(g_sigShift[newest] != 1)
      return;                                  // the signal is not on the bar that just closed

   datetime stamp = Time[1];
   if(stamp == g_handledSignal)
      return;
   g_handledSignal = stamp;
   if(g_stateKey != "")
      GlobalVariableSet(g_stateKey, (double)stamp);

   int direction = g_sigDir[newest];

   if(!IsTradeAllowed())
   {
      Print(OrderPrefix, " trading is not allowed by the terminal");
      return;
   }
   if(!InsideSession())
      return;

   ResetDailyCounter();
   if(MaxTradesPerDay > 0 && g_tradesToday >= MaxTradesPerDay)
      return;
   if(MaxSpreadPoints > 0 && SpreadPoints() > MaxSpreadPoints)
   {
      Print(OrderPrefix, " spread too wide (", DoubleToString(SpreadPoints(), 1), " points), signal skipped");
      return;
   }
   if(!MtfAgrees(direction))
      return;

   int openDirection = 0;
   int openCount = CountOwnPositions(openDirection);
   if(openCount > 0)
   {
      if(openDirection == direction)
         return;
      if(CloseOnOpposite)
         CloseOwnPositions(openDirection);
      else if(OnlyOnePosition)
         return;
      openCount = CountOwnPositions(openDirection);
      if(openCount > 0 && OnlyOnePosition)
         return;
   }

   double entry = 0.0, stop = 0.0, target = 0.0;
   BuildLevels(direction, newest, entry, stop, target);

   double lot = LotForRisk(MathAbs(entry - stop));
   if(lot <= 0)
   {
      Print(OrderPrefix, " lot came out as zero, check RiskPercent, the stop distance and the free margin");
      return;
   }

   string comment = OrderPrefix + " " + (direction > 0 ? "BULL" : "BEAR") +
                    (g_sigChoch[newest] ? " CHoCH" : " BOS");
   int ticket = SendMarketOrder(direction, lot, stop, target, comment);
   if(ticket > 0)
   {
      g_tradesToday++;
      Print(OrderPrefix, " ", (direction > 0 ? "BUY" : "SELL"), " ticket ", ticket,
            " lot ", DoubleToString(lot, 2),
            " entry ", DoubleToString(entry, Digits),
            " SL ", DoubleToString(stop, Digits),
            " TP ", DoubleToString(target, Digits));
   }
}

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if(SwingLength < 1 || MtfSwingLength < 1 || PanelSwingLength < 1)
   {
      Print("GTE V7: the swing lengths must be 1 or more");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(RewardRatio <= 0)
   {
      Print("GTE V7: RewardRatio must be greater than zero");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(ZoneLookback < 1 || ScanBars < 50)
   {
      Print("GTE V7: ZoneLookback must be >= 1 and ScanBars >= 50");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_prefix = "GTEv7_" + IntegerToString(MagicNumber) + "_";
   g_stateKey = "GTEv7_" + Symbol() + "_" + IntegerToString(MagicNumber);
   if(GlobalVariableCheck(g_stateKey))
      g_handledSignal = (datetime)GlobalVariableGet(g_stateKey);
   else if(Bars > 1)
      g_handledSignal = Time[1];   // do not fire on a signal that is already history

   ResetDailyCounter();
   g_lastBarTime = 0;
   Print("GTE V7 EA started on ", Symbol(), " ", Period(), " minutes, magic ", MagicNumber,
         TradeEnabled ? "" : " (drawing only, trading disabled)");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   DeleteOwnObjects("");
   Comment("");
}

void OnTick()
{
   ManageBreakEven();

   if(Bars < SwingLength * 2 + 20)
      return;

   bool newBar = (Time[0] != g_lastBarTime);
   if(!newBar)
      return;
   g_lastBarTime = Time[0];

   ScanStructure();
   DrawSignals();
   DrawPanel();
   TryTrade();
}
//+------------------------------------------------------------------+
