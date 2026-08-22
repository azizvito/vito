//+------------------------------------------------------------------+
//|  GTE V7 EA  -  Gold Trend Engine V7 for MetaTrader 5             |
//|                                                                  |
//|  Same structure engine as the Pine indicator and the MT4 bot:    |
//|    swing pivots -> break of structure / CHoCH -> BULL / BEAR      |
//|    the last opposite candle before the impulse is the order block |
//|                                                                  |
//|  MT5 additions asked for:                                        |
//|    * stop loss under the buy candle / above the sell candle       |
//|    * trailing stop (ATR, fixed points or R based)                 |
//|    * profit locking: break even + partial close                   |
//|    * trades are only opened with the trend                        |
//|    * ready made preset with sane distances for the M1 chart       |
//+------------------------------------------------------------------+
#property copyright "GTE V7"
#property link      ""
#property version   "1.00"
#property description "Gold Trend Engine V7 - structure bot with trailing and profit locking"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum GtePreset
{
   GTE_PRESET_CUSTOM  = 0,  // Custom (use the inputs below)
   GTE_PRESET_M1      = 1,  // M1 scalping, many trades, small targets
   GTE_PRESET_M1_WIDE = 4,  // M1 trend runner, fewer trades, wide targets
   GTE_PRESET_M5      = 2,  // M5 standard
   GTE_PRESET_M15     = 3   // M15 swing
};

enum GteStopMode
{
   GTE_STOP_CANDLE = 0,     // Under the signal candle (over it for a sell)
   GTE_STOP_ZONE   = 1,     // Behind the order block
   GTE_STOP_ATR    = 2      // ATR distance
};

enum GteTrailMode
{
   GTE_TRAIL_OFF    = 0,    // No trailing
   GTE_TRAIL_ATR    = 1,    // Distance = ATR x multiplier
   GTE_TRAIL_POINTS = 2,    // Fixed distance in points
   GTE_TRAIL_R      = 3     // Distance = risk x factor
};

enum GteTrendFilter
{
   GTE_TREND_OFF    = 0,    // Trade every signal
   GTE_TREND_FAST   = 1,    // Fast timeframes must agree
   GTE_TREND_HIGHER = 2,    // Higher timeframes must agree
   GTE_TREND_BOTH   = 3     // Both groups must agree
};

enum GteZoneSource { GTE_ZONE_WICK = 0, GTE_ZONE_BODY = 1 };
enum GteLanguage   { GTE_ENGLISH = 0, GTE_ARABIC = 1 };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "0  Preset"
input GtePreset Preset            = GTE_PRESET_M1;   // Ready made settings
input bool   AutoScalePoints      = true;            // Same distance in money on 2 and 3 digit gold

input group "1  Market structure"
input int    SwingLength          = 5;      // Swing length (bars each side)
input bool   ConfirmWithClose     = true;   // Confirm the break with the close
input bool   ShiftOnly            = false;  // Only reversals (CHoCH)
input GteZoneSource ZoneSource    = GTE_ZONE_WICK;
input int    ZoneLookback         = 100;    // Bars searched for the base candle
input int    ScanBars             = 600;    // History replayed on every new bar

input group "2  Stop loss"
input GteStopMode StopMode        = GTE_STOP_CANDLE; // Where the stop goes
input double StopBufferPoints     = 15;     // Buffer under the candle / zone (points)
input double MinStopPoints        = 60;     // Never closer than this (points)
input double MaxStopPoints        = 900;    // Never wider than this (points, 0 = off)
input double MinStopAtrMult       = 0.8;    // Never closer than ATR x this (0 = off)
input double StopAtrMult          = 1.5;    // ATR multiplier when StopMode = ATR
input int    AtrPeriod            = 14;     // ATR period

input group "3  Take profit and profit locking"
input double RewardRatio          = 1.5;    // Target as an R multiple (0 = no fixed target)
input double BreakEvenAtR         = 0.8;    // Move the stop to entry at this R (0 = off)
input double BreakEvenLockPoints  = 10;     // Points of profit locked with the break even
input double PartialAtR           = 1.0;    // Close a part of the position at this R (0 = off)
input double PartialPercent       = 50;     // Percent of the position closed there

input group "4  Trailing stop"
input GteTrailMode TrailMode      = GTE_TRAIL_ATR; // Trailing method
input double TrailStartR          = 1.0;    // Start trailing at this R
input double TrailAtrMult         = 1.0;    // ATR multiplier (ATR mode)
input double TrailPoints          = 250;    // Distance in points (points mode)
input double TrailRFactor         = 1.0;    // Distance = risk x this (R mode)
input double TrailStepPoints      = 20;     // Minimum improvement before moving the stop

input group "5  Trend filter"
input GteTrendFilter TrendFilter  = GTE_TREND_FAST; // Only trade with the trend
input int    FastMinutes1         = 1;      // Fast timeframe 1 (minutes)
input int    FastMinutes2         = 3;      // Fast timeframe 2 (minutes)
input int    FastMinutes3         = 5;      // Fast timeframe 3 (minutes)
input int    HigherMinutes1       = 15;     // Higher timeframe 1 (minutes)
input int    HigherMinutes2       = 30;     // Higher timeframe 2 (minutes)
input int    TrendSwingLength     = 5;      // Swing length inside each timeframe
input bool   UseEmaFilter         = false;  // Extra filter: price on the right side of an EMA
input int    EmaPeriod            = 200;    // EMA period
input int    EmaMinutes           = 5;      // Timeframe of the EMA (minutes)

input group "6  Risk and money"
input bool   TradeEnabled         = true;   // false = draw only, no orders
input double RiskPercent          = 0.5;    // Risk per trade, percent of the balance
input double FixedLot             = 0;      // > 0 uses this lot and ignores the risk
input double MaxSpreadPoints      = 40;     // Skip the signal above this spread
input int    SlippagePoints       = 30;     // Allowed slippage
input int    MaxTradesPerDay      = 0;      // 0 = unlimited
input bool   CloseOnOpposite      = true;   // Close on the opposite signal
input bool   UseSession           = false;  // Trade only inside a time window
input string SessionStart         = "03:00"; // Session start (server time)
input string SessionEnd           = "21:00"; // Session end (server time)
input long   MagicNumber          = 770057; // Order id of this EA

input group "7  Chart objects"
input bool   ShowSignals          = true;
input bool   ShowZones            = true;
input bool   ShowMidLine          = true;
input bool   ShowZonePrice        = true;
input bool   KeepMitigated        = true;
input int    MaxDrawnSignals      = 25;
input int    ZoneExtendBars       = 40;
input color  BullColor            = clrSeaGreen;
input color  BearColor            = clrCrimson;
input color  BullZoneColor        = C'12,48,32';
input color  BearZoneColor        = C'62,20,24';
input color  DeadZoneColor        = C'42,42,46';
input color  TextColor            = clrWhite;

input group "8  Trend panel"
input bool   ShowPanel            = true;
input bool   ShowPanelBackground  = true;
input GteLanguage PanelLanguage   = GTE_ARABIC;
input int    PanelMinutes1        = 1;
input int    PanelMinutes2        = 3;
input int    PanelMinutes3        = 5;
input int    PanelMinutes4        = 10;
input int    PanelMinutes5        = 15;
input int    PanelMinutes6        = 25;
input int    PanelX               = 12;
input int    PanelY               = 20;
input int    PanelFontSize        = 9;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
#define GTE_MAX_SIGNALS 400
#define GTE_TF_BARS     260

CTrade   g_trade;

// effective parameters, a preset may override the inputs
int      g_swingLength;
bool     g_shiftOnly;
GteStopMode  g_stopMode;
double   g_stopBuffer;        // in price units
double   g_minStop;           // in price units
double   g_maxStop;           // in price units
double   g_minStopAtr;
double   g_rewardRatio;
double   g_breakEvenR;
double   g_breakEvenLock;     // in price units
double   g_partialR;
double   g_partialPercent;
GteTrailMode g_trailMode;
double   g_trailStartR;
double   g_trailAtr;
double   g_trailDistance;     // in price units (points mode)
double   g_trailRFactor;
double   g_trailStep;         // in price units
double   g_maxSpread;         // in price units
GteTrendFilter g_trendFilter;

double   g_pointScale = 1.0;  // 10 on 3/5 digit quotes when AutoScalePoints is on
double   g_point      = 0.0;
int      g_digits     = 2;

// signal storage, index 0 is the oldest scanned signal
int      g_sigShift[GTE_MAX_SIGNALS];
int      g_sigDir[GTE_MAX_SIGNALS];
bool     g_sigChoch[GTE_MAX_SIGNALS];
double   g_sigZoneTop[GTE_MAX_SIGNALS];
double   g_sigZoneBot[GTE_MAX_SIGNALS];
int      g_sigZoneShift[GTE_MAX_SIGNALS];
double   g_sigCandleHigh[GTE_MAX_SIGNALS];
double   g_sigCandleLow[GTE_MAX_SIGNALS];
int      g_sigCount = 0;
int      g_trend    = 0;

MqlRates g_rates[];
int      g_ratesCount = 0;

int      g_atrHandle = INVALID_HANDLE;
int      g_emaHandle = INVALID_HANDLE;

string   g_prefix        = "GTEv7_";
string   g_stateKey      = "";
datetime g_handledSignal = 0;
datetime g_lastBarTime   = 0;
int      g_tradesToday   = 0;
int      g_tradeDay      = -1;

// remembered risk per position, so R based logic survives a stop that already moved
ulong    g_riskTicket[64];
double   g_riskEntry[64];
double   g_riskSize[64];
bool     g_riskPartial[64];
int      g_riskCount = 0;

//+------------------------------------------------------------------+
//| Series helpers, index 0 is the newest bar                        |
//+------------------------------------------------------------------+
double BarHigh(const int shift)  { return(g_rates[shift].high);  }
double BarLow(const int shift)   { return(g_rates[shift].low);   }
double BarOpen(const int shift)  { return(g_rates[shift].open);  }
double BarClose(const int shift) { return(g_rates[shift].close); }
datetime BarTime(const int shift){ return(g_rates[shift].time);  }

bool LoadRates()
{
   int wanted = ScanBars + g_swingLength * 2 + 10;
   ArraySetAsSeries(g_rates, true);
   g_ratesCount = CopyRates(_Symbol, PERIOD_CURRENT, 0, wanted, g_rates);
   if(g_ratesCount <= 0)
   {
      g_ratesCount = 0;
      return(false);
   }
   return(true);
}

double AtrValue(const int shift = 1)
{
   if(g_atrHandle == INVALID_HANDLE)
      return(0.0);
   double buffer[];
   if(CopyBuffer(g_atrHandle, 0, shift, 1, buffer) <= 0)
      return(0.0);
   return(buffer[0]);
}

double EmaValue(const int shift = 1)
{
   if(g_emaHandle == INVALID_HANDLE)
      return(0.0);
   double buffer[];
   if(CopyBuffer(g_emaHandle, 0, shift, 1, buffer) <= 0)
      return(0.0);
   return(buffer[0]);
}

double Spread()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return(0.0);
   return(tick.ask - tick.bid);
}

double StopLevelDistance()
{
   double stops = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
   double freeze = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * g_point;
   double level = MathMax(stops, freeze);
   if(level <= 0.0)
      level = 2.0 * g_point;
   return(level);
}

//+------------------------------------------------------------------+
//| Preset                                                           |
//+------------------------------------------------------------------+
double Points(const double value)
{
   return(value * g_point * g_pointScale);
}

void ApplyPreset()
{
   // start from the inputs
   g_swingLength   = SwingLength;
   g_shiftOnly     = ShiftOnly;
   g_stopMode      = StopMode;
   g_stopBuffer    = Points(StopBufferPoints);
   g_minStop       = Points(MinStopPoints);
   g_maxStop       = Points(MaxStopPoints);
   g_minStopAtr    = MinStopAtrMult;
   g_rewardRatio   = RewardRatio;
   g_breakEvenR    = BreakEvenAtR;
   g_breakEvenLock = Points(BreakEvenLockPoints);
   g_partialR      = PartialAtR;
   g_partialPercent = PartialPercent;
   g_trailMode     = TrailMode;
   g_trailStartR   = TrailStartR;
   g_trailAtr      = TrailAtrMult;
   g_trailDistance = Points(TrailPoints);
   g_trailRFactor  = TrailRFactor;
   g_trailStep     = Points(TrailStepPoints);
   g_maxSpread     = Points(MaxSpreadPoints);
   g_trendFilter   = TrendFilter;

   if(Preset == GTE_PRESET_CUSTOM)
      return;

   // shared by every preset: the candle stop is what the presets are built around
   g_stopMode = GTE_STOP_CANDLE;

   if(Preset == GTE_PRESET_M1)
   {
      g_swingLength    = 5;
      g_shiftOnly      = false;
      g_stopBuffer     = Points(15);    // 0.15 on gold
      g_minStop        = Points(60);    // 0.60 on gold, survives M1 noise
      g_maxStop        = Points(400);
      g_minStopAtr     = 0.8;
      g_rewardRatio    = 1.5;
      g_breakEvenR     = 0.8;
      g_breakEvenLock  = Points(10);
      g_partialR       = 1.0;
      g_partialPercent = 50;
      g_trailMode      = GTE_TRAIL_ATR;
      g_trailStartR    = 1.0;
      g_trailAtr       = 1.0;
      g_trailStep      = Points(20);
      g_maxSpread      = Points(40);
      g_trendFilter    = GTE_TREND_FAST;
   }
   else if(Preset == GTE_PRESET_M1_WIDE)
   {
      // Built for a low win rate: at 33% winners the average win has to be
      // about 2x the average loss, so the target is wide, nothing is taken off
      // early, and the stop only moves once the trade is clearly working.
      g_swingLength    = 5;
      g_shiftOnly      = true;      // reversals only, far fewer entries
      g_stopBuffer     = Points(15);
      g_minStop        = Points(80);   // 0.80 on gold, the target must beat the spread
      g_maxStop        = Points(400);
      g_minStopAtr     = 1.0;
      g_rewardRatio    = 3.0;
      g_breakEvenR     = 1.5;          // late, so winners are not strangled
      g_breakEvenLock  = Points(20);
      g_partialR       = 0.0;          // no partial close, the runners pay for the losers
      g_partialPercent = 0;
      g_trailMode      = GTE_TRAIL_ATR;
      g_trailStartR    = 2.0;
      g_trailAtr       = 1.5;
      g_trailStep      = Points(30);
      g_maxSpread      = Points(25);    // spread is a large share of a small stop
      g_trendFilter    = GTE_TREND_BOTH;
   }
   else if(Preset == GTE_PRESET_M5)
   {
      g_swingLength    = 8;
      g_shiftOnly      = true;
      g_stopBuffer     = Points(20);
      g_minStop        = Points(120);
      g_maxStop        = Points(800);
      g_minStopAtr     = 0.7;
      g_rewardRatio    = 2.0;
      g_breakEvenR     = 1.0;
      g_breakEvenLock  = Points(15);
      g_partialR       = 1.0;
      g_partialPercent = 50;
      g_trailMode      = GTE_TRAIL_ATR;
      g_trailStartR    = 1.2;
      g_trailAtr       = 1.5;
      g_trailStep      = Points(30);
      g_maxSpread      = Points(60);
      g_trendFilter    = GTE_TREND_FAST;
   }
   else if(Preset == GTE_PRESET_M15)
   {
      g_swingLength    = 8;
      g_shiftOnly      = true;
      g_stopBuffer     = Points(30);
      g_minStop        = Points(250);
      g_maxStop        = Points(1500);
      g_minStopAtr     = 0.6;
      g_rewardRatio    = 2.5;
      g_breakEvenR     = 1.0;
      g_breakEvenLock  = Points(20);
      g_partialR       = 1.5;
      g_partialPercent = 50;
      g_trailMode      = GTE_TRAIL_ATR;
      g_trailStartR    = 1.5;
      g_trailAtr       = 2.0;
      g_trailStep      = Points(50);
      g_maxSpread      = Points(80);
      g_trendFilter    = GTE_TREND_HIGHER;
   }
}

//+------------------------------------------------------------------+
//| Session and daily counter                                        |
//+------------------------------------------------------------------+
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
   int end = ParseClock(SessionEnd);
   if(start < 0 || end < 0)
      return(true);
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   int minutes = now.hour * 60 + now.min;
   if(start <= end)
      return(minutes >= start && minutes < end);
   return(minutes >= start || minutes < end);
}

void ResetDailyCounter()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   if(now.day_of_year != g_tradeDay)
   {
      g_tradeDay = now.day_of_year;
      g_tradesToday = 0;
   }
}

//+------------------------------------------------------------------+
//| Structure engine                                                 |
//+------------------------------------------------------------------+
bool IsPivotHigh(const int shift, const int length)
{
   if(shift - length < 0 || shift + length >= g_ratesCount)
      return(false);
   double value = BarHigh(shift);
   for(int step = 1; step <= length; step++)
   {
      if(BarHigh(shift + step) >= value)
         return(false);
      if(BarHigh(shift - step) >= value)
         return(false);
   }
   return(true);
}

bool IsPivotLow(const int shift, const int length)
{
   if(shift - length < 0 || shift + length >= g_ratesCount)
      return(false);
   double value = BarLow(shift);
   for(int step = 1; step <= length; step++)
   {
      if(BarLow(shift + step) <= value)
         return(false);
      if(BarLow(shift - step) <= value)
         return(false);
   }
   return(true);
}

int BaseCandleShift(const int shift, const int direction)
{
   int limit = (int)MathMin(ZoneLookback, g_ratesCount - shift - 2);
   for(int back = 1; back <= limit; back++)
   {
      int candle = shift + back;
      bool isBase = (direction > 0) ? (BarClose(candle) < BarOpen(candle))
                                    : (BarClose(candle) > BarOpen(candle));
      if(isBase)
         return(candle);
   }
   return(shift);
}

void PushSignal(const int shift, const int direction, const bool choch)
{
   if(g_sigCount >= GTE_MAX_SIGNALS)
      return;
   int candle = BaseCandleShift(shift, direction);
   double top = BarHigh(candle);
   double bottom = BarLow(candle);
   if(ZoneSource == GTE_ZONE_BODY)
   {
      top = MathMax(BarOpen(candle), BarClose(candle));
      bottom = MathMin(BarOpen(candle), BarClose(candle));
   }

   g_sigShift[g_sigCount]      = shift;
   g_sigDir[g_sigCount]        = direction;
   g_sigChoch[g_sigCount]      = choch;
   g_sigZoneShift[g_sigCount]  = candle;
   g_sigZoneTop[g_sigCount]    = top;
   g_sigZoneBot[g_sigCount]    = bottom;
   g_sigCandleHigh[g_sigCount] = BarHigh(shift);
   g_sigCandleLow[g_sigCount]  = BarLow(shift);
   g_sigCount++;
}

void ScanStructure()
{
   g_sigCount = 0;
   g_trend = 0;

   int available = g_ratesCount - g_swingLength - 2;
   int start = (int)MathMin(ScanBars, available);
   if(start < g_swingLength * 2 + 5)
      return;

   double swingHigh = 0.0, swingLow = 0.0;
   bool haveHigh = false, haveLow = false;
   bool highTaken = true, lowTaken = true;

   for(int shift = start; shift >= 1; shift--)
   {
      int candidate = shift + g_swingLength;

      if(IsPivotHigh(candidate, g_swingLength))
      {
         swingHigh = BarHigh(candidate);
         haveHigh = true;
         highTaken = false;
      }
      if(IsPivotLow(candidate, g_swingLength))
      {
         swingLow = BarLow(candidate);
         haveLow = true;
         lowTaken = false;
      }

      double sourceUp = ConfirmWithClose ? BarClose(shift) : BarHigh(shift);
      double sourceDown = ConfirmWithClose ? BarClose(shift) : BarLow(shift);

      bool brokeHigh = haveHigh && !highTaken && sourceUp > swingHigh;
      bool brokeLow = haveLow && !lowTaken && sourceDown < swingLow;

      if(brokeHigh)
      {
         bool chochUp = (g_trend <= 0);
         bool emitUp = g_shiftOnly ? chochUp : true;
         highTaken = true;
         g_trend = 1;
         if(emitUp)
            PushSignal(shift, 1, chochUp);
      }
      if(brokeLow)
      {
         bool chochDown = (g_trend >= 0);
         bool emitDown = g_shiftOnly ? chochDown : true;
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
ENUM_TIMEFRAMES NativePeriod(const int minutes)
{
   switch(minutes)
   {
      case 1:    return(PERIOD_M1);
      case 2:    return(PERIOD_M2);
      case 3:    return(PERIOD_M3);
      case 4:    return(PERIOD_M4);
      case 5:    return(PERIOD_M5);
      case 6:    return(PERIOD_M6);
      case 10:   return(PERIOD_M10);
      case 12:   return(PERIOD_M12);
      case 15:   return(PERIOD_M15);
      case 20:   return(PERIOD_M20);
      case 30:   return(PERIOD_M30);
      case 60:   return(PERIOD_H1);
      case 120:  return(PERIOD_H2);
      case 180:  return(PERIOD_H3);
      case 240:  return(PERIOD_H4);
      case 1440: return(PERIOD_D1);
   }
   return(PERIOD_CURRENT);
}

// fills the arrays with the newest bars of a timeframe, index 0 = newest
int LoadTimeframe(const int minutes, double &highs[], double &lows[], double &closes[], const int wanted)
{
   ArrayResize(highs, wanted);
   ArrayResize(lows, wanted);
   ArrayResize(closes, wanted);

   ENUM_TIMEFRAMES period = NativePeriod(minutes);
   if(period != PERIOD_CURRENT)
   {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(_Symbol, period, 0, wanted, rates);
      if(copied <= 0)
         return(0);
      for(int shift = 0; shift < copied; shift++)
      {
         highs[shift] = rates[shift].high;
         lows[shift] = rates[shift].low;
         closes[shift] = rates[shift].close;
      }
      return(copied);
   }

   // no native period (25 minutes for example): build the bars from M1
   int seconds = minutes * 60;
   if(seconds <= 0)
      return(0);
   MqlRates minute[];
   ArraySetAsSeries(minute, true);
   int scan = CopyRates(_Symbol, PERIOD_M1, 0, wanted * minutes + minutes * 4, minute);
   if(scan <= 0)
      return(0);

   int count = -1;
   datetime bucket = 0;
   for(int index = 0; index < scan; index++)
   {
      datetime stamp = minute[index].time;
      datetime start = (datetime)(stamp - (stamp % seconds));
      if(count < 0 || start != bucket)
      {
         count++;
         if(count >= wanted)
            return(wanted);
         bucket = start;
         highs[count] = minute[index].high;
         lows[count] = minute[index].low;
         closes[count] = minute[index].close;   // the newest M1 closes the bucket
      }
      else
      {
         highs[count] = MathMax(highs[count], minute[index].high);
         lows[count] = MathMin(lows[count], minute[index].low);
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

// "open trades with the trend": every requested group must agree with the signal
bool TrendAgrees(const int direction, string &reason)
{
   if(g_trendFilter == GTE_TREND_FAST || g_trendFilter == GTE_TREND_BOTH)
   {
      int one = TimeframeTrend(FastMinutes1, TrendSwingLength);
      int two = TimeframeTrend(FastMinutes2, TrendSwingLength);
      int three = TimeframeTrend(FastMinutes3, TrendSwingLength);
      bool ok = (direction > 0) ? (one > 0 && two > 0 && three > 0)
                                : (one < 0 && two < 0 && three < 0);
      if(!ok)
      {
         reason = StringFormat("fast timeframes disagree (%d/%d/%d)", one, two, three);
         return(false);
      }
   }

   if(g_trendFilter == GTE_TREND_HIGHER || g_trendFilter == GTE_TREND_BOTH)
   {
      int one = TimeframeTrend(HigherMinutes1, TrendSwingLength);
      int two = TimeframeTrend(HigherMinutes2, TrendSwingLength);
      bool ok = (direction > 0) ? (one > 0 && two > 0) : (one < 0 && two < 0);
      if(!ok)
      {
         reason = StringFormat("higher timeframes disagree (%d/%d)", one, two);
         return(false);
      }
   }

   if(UseEmaFilter && g_emaHandle != INVALID_HANDLE)
   {
      double ema = EmaValue(0);
      double price = BarClose(1);
      if(ema > 0.0)
      {
         bool ok = (direction > 0) ? (price > ema) : (price < ema);
         if(!ok)
         {
            reason = "price is on the wrong side of the EMA";
            return(false);
         }
      }
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Position bookkeeping                                             |
//+------------------------------------------------------------------+
void RememberRisk(const ulong ticket, const double entry, const double risk)
{
   for(int index = 0; index < g_riskCount; index++)
   {
      if(g_riskTicket[index] == ticket)
      {
         g_riskEntry[index] = entry;
         g_riskSize[index] = risk;
         g_riskPartial[index] = false;
         return;
      }
   }
   if(g_riskCount >= 64)
      g_riskCount = 0;                   // ring buffer, old tickets are gone anyway
   g_riskTicket[g_riskCount] = ticket;
   g_riskEntry[g_riskCount] = entry;
   g_riskSize[g_riskCount] = risk;
   g_riskPartial[g_riskCount] = false;
   g_riskCount++;
}

int RiskSlot(const ulong ticket)
{
   for(int index = 0; index < g_riskCount; index++)
      if(g_riskTicket[index] == ticket)
         return(index);
   return(-1);
}

// the original risk, so the R math still works after the stop has moved
double RiskOf(const ulong ticket, const double entry, const double stop)
{
   int slot = RiskSlot(ticket);
   if(slot >= 0 && g_riskSize[slot] > 0.0)
      return(g_riskSize[slot]);

   // the EA was restarted while the position was open, rebuild a sane estimate
   double fallback = MathAbs(entry - stop);
   double atr = AtrValue(1);
   double floorRisk = g_minStop;
   if(g_minStopAtr > 0.0 && atr > 0.0)
      floorRisk = MathMax(floorRisk, atr * g_minStopAtr);
   if(fallback < floorRisk * 0.5)
      fallback = floorRisk;
   return(fallback);
}

int CountOwnPositions(int &direction)
{
   int total = 0;
   direction = 0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      total++;
      direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   }
   return(total);
}

bool CloseOwnPositions(const int onlyDirection, const string reason)
{
   bool closed = false;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      int direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(onlyDirection != 0 && direction != onlyDirection)
         continue;
      if(g_trade.PositionClose(ticket, SlippagePoints))
      {
         closed = true;
         PrintFormat("GTE V7: closed #%I64u (%s)", ticket, reason);
      }
      else
         PrintFormat("GTE V7: closing #%I64u failed, retcode %d (%s)",
                     ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
   return(closed);
}

//+------------------------------------------------------------------+
//| Lot size                                                         |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   if(minimum <= 0.0)
      minimum = step;

   lot = MathFloor(lot / step + 0.0000001) * step;
   if(lot > maximum)
      lot = maximum;
   if(lot < minimum)
      return(0.0);
   return(NormalizeDouble(lot, 2));
}

double LotForRisk(const double stopDistance)
{
   if(FixedLot > 0.0)
      return(NormalizeLot(FixedLot));
   if(stopDistance <= 0.0 || RiskPercent <= 0.0)
      return(0.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = g_point;
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return(0.0);

   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return(0.0);

   double money = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double lot = NormalizeLot(money / lossPerLot);

   // shrink while the margin is not enough
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   double margin = 0.0;
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick))
   {
      int guard = 0;
      while(lot > 0.0 && guard < 100)
      {
         if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, tick.ask, margin))
            break;
         if(margin <= AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
            break;
         lot = NormalizeLot(lot - step);
         guard++;
      }
   }
   return(lot);
}

//+------------------------------------------------------------------+
//| Stop and target                                                  |
//+------------------------------------------------------------------+
void BuildLevels(const int direction, const int signalIndex, const double entry,
                 double &stop, double &target)
{
   double atr = AtrValue(1);
   if(atr <= 0.0)
      atr = 10.0 * g_point;

   if(g_stopMode == GTE_STOP_ATR)
      stop = (direction > 0) ? entry - atr * StopAtrMult : entry + atr * StopAtrMult;
   else if(g_stopMode == GTE_STOP_ZONE)
      stop = (direction > 0) ? g_sigZoneBot[signalIndex] - g_stopBuffer
                             : g_sigZoneTop[signalIndex] + g_stopBuffer;
   else
      stop = (direction > 0) ? g_sigCandleLow[signalIndex] - g_stopBuffer
                             : g_sigCandleHigh[signalIndex] + g_stopBuffer;

   double distance = MathAbs(entry - stop);
   double floorDistance = g_minStop;
   if(g_minStopAtr > 0.0)
      floorDistance = MathMax(floorDistance, atr * g_minStopAtr);
   floorDistance = MathMax(floorDistance, StopLevelDistance() + g_point);

   if(distance < floorDistance)
      distance = floorDistance;
   if(g_maxStop > 0.0 && distance > g_maxStop)
      distance = g_maxStop;

   stop = (direction > 0) ? entry - distance : entry + distance;

   if(g_rewardRatio <= 0.0)
   {
      target = 0.0;
      return;
   }
   target = (direction > 0) ? entry + distance * g_rewardRatio : entry - distance * g_rewardRatio;

   double minimum = StopLevelDistance();
   if(direction > 0 && target - entry < minimum)
      target = entry + minimum;
   if(direction < 0 && entry - target < minimum)
      target = entry - minimum;
}

//+------------------------------------------------------------------+
//| Profit locking: break even, partial close, trailing              |
//+------------------------------------------------------------------+
double TrailingDistance(const double risk)
{
   if(g_trailMode == GTE_TRAIL_ATR)
   {
      double atr = AtrValue(1);
      if(atr <= 0.0)
         return(0.0);
      return(atr * g_trailAtr);
   }
   if(g_trailMode == GTE_TRAIL_POINTS)
      return(g_trailDistance);
   if(g_trailMode == GTE_TRAIL_R)
      return(risk * g_trailRFactor);
   return(0.0);
}

void ManagePosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;

   int direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double stop = PositionGetDouble(POSITION_SL);
   double target = PositionGetDouble(POSITION_TP);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double risk = RiskOf(ticket, entry, stop);
   if(risk <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double current = (direction > 0) ? tick.bid : tick.ask;
   double progress = (direction > 0) ? (current - entry) / risk : (entry - current) / risk;

   double newStop = stop;
   string action = "";

   // 1) break even, with a few points of profit locked
   if(g_breakEvenR > 0.0 && progress >= g_breakEvenR)
   {
      double locked = (direction > 0) ? entry + g_breakEvenLock : entry - g_breakEvenLock;
      if(direction > 0 && (stop <= 0.0 || locked > stop))
      {
         newStop = locked;
         action = "break even";
      }
      if(direction < 0 && (stop <= 0.0 || locked < stop))
      {
         newStop = locked;
         action = "break even";
      }
   }

   // 2) trailing stop
   if(g_trailMode != GTE_TRAIL_OFF && progress >= g_trailStartR)
   {
      double distance = TrailingDistance(risk);
      if(distance > 0.0)
      {
         double candidate = (direction > 0) ? current - distance : current + distance;
         if(direction > 0 && candidate > newStop + g_trailStep - g_point * 0.5)
         {
            newStop = candidate;
            action = "trailing";
         }
         if(direction < 0 && (newStop <= 0.0 || candidate < newStop - g_trailStep + g_point * 0.5))
         {
            newStop = candidate;
            action = "trailing";
         }
      }
   }

   // never let the trailing stop move into a loss once break even was reached
   if(g_breakEvenR > 0.0 && progress >= g_breakEvenR)
   {
      if(direction > 0)
         newStop = MathMax(newStop, entry + g_breakEvenLock);
      else
         newStop = MathMin(newStop, entry - g_breakEvenLock);
   }

   // keep the broker minimum distance
   double minimum = StopLevelDistance();
   if(direction > 0 && current - newStop < minimum)
      newStop = current - minimum;
   if(direction < 0 && newStop - current < minimum)
      newStop = current + minimum;

   newStop = NormalizeDouble(newStop, g_digits);
   bool improved = (direction > 0) ? (newStop > stop + g_point * 0.5)
                                   : (stop <= 0.0 || newStop < stop - g_point * 0.5);
   if(action != "" && improved)
   {
      if(g_trade.PositionModify(ticket, newStop, target))
         PrintFormat("GTE V7: %s on #%I64u, stop -> %s", action, ticket,
                     DoubleToString(newStop, g_digits));
      else
         PrintFormat("GTE V7: stop update on #%I64u failed, retcode %d",
                     ticket, g_trade.ResultRetcode());
   }

   // 3) partial profit taking
   int slot = RiskSlot(ticket);
   bool alreadyTaken = (slot >= 0) ? g_riskPartial[slot] : true;
   if(g_partialR > 0.0 && g_partialPercent > 0.0 && !alreadyTaken && progress >= g_partialR)
   {
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minimum_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(step <= 0.0)
         step = 0.01;
      if(minimum_lot <= 0.0)
         minimum_lot = step;

      double part = MathFloor((volume * g_partialPercent / 100.0) / step + 0.0000001) * step;
      part = NormalizeDouble(part, 2);
      if(part >= minimum_lot && volume - part >= minimum_lot)
      {
         if(g_trade.PositionClosePartial(ticket, part, SlippagePoints))
         {
            if(slot >= 0)
               g_riskPartial[slot] = true;
            PrintFormat("GTE V7: locked profit on #%I64u, closed %s of %s lots at %.1fR",
                        ticket, DoubleToString(part, 2), DoubleToString(volume, 2), progress);
         }
         else
            PrintFormat("GTE V7: partial close on #%I64u failed, retcode %d",
                        ticket, g_trade.ResultRetcode());
      }
      else if(slot >= 0)
         g_riskPartial[slot] = true;   // position too small to split, do not retry
   }
}

void ManageAllPositions()
{
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      ManagePosition(ticket);
   }
}

//+------------------------------------------------------------------+
//| Trading                                                          |
//+------------------------------------------------------------------+
void TryTrade()
{
   if(!TradeEnabled || g_sigCount <= 0)
      return;

   int newest = g_sigCount - 1;
   if(g_sigShift[newest] != 1)
      return;                                    // not the bar that just closed

   datetime stamp = BarTime(1);
   if(stamp == g_handledSignal)
      return;
   g_handledSignal = stamp;
   if(g_stateKey != "")
      GlobalVariableSet(g_stateKey, (double)stamp);

   int direction = g_sigDir[newest];

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("GTE V7: trading is not allowed in the terminal");
      return;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("GTE V7: allow algorithmic trading in the EA properties");
      return;
   }
   if(!InsideSession())
      return;

   ResetDailyCounter();
   if(MaxTradesPerDay > 0 && g_tradesToday >= MaxTradesPerDay)
      return;

   double spread = Spread();
   if(g_maxSpread > 0.0 && spread > g_maxSpread)
   {
      PrintFormat("GTE V7: spread %s is too wide, signal skipped",
                  DoubleToString(spread / g_point, 0));
      return;
   }

   string reason = "";
   if(!TrendAgrees(direction, reason))
   {
      PrintFormat("GTE V7: %s signal skipped, %s", (direction > 0 ? "BULL" : "BEAR"), reason);
      return;
   }

   int openDirection = 0;
   int openCount = CountOwnPositions(openDirection);
   if(openCount > 0)
   {
      if(openDirection == direction)
         return;
      if(!CloseOnOpposite)
         return;
      CloseOwnPositions(openDirection, direction > 0 ? "Close SELL" : "Close BUY");
      openCount = CountOwnPositions(openDirection);
      if(openCount > 0)
         return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double entry = (direction > 0) ? tick.ask : tick.bid;

   double stop = 0.0, target = 0.0;
   BuildLevels(direction, newest, entry, stop, target);
   double risk = MathAbs(entry - stop);

   double lot = LotForRisk(risk);
   if(lot <= 0.0)
   {
      Print("GTE V7: lot came out as zero, check RiskPercent, the stop distance and the free margin");
      return;
   }

   string comment = StringFormat("GTE V7 %s %s", (direction > 0 ? "BULL" : "BEAR"),
                                 (g_sigChoch[newest] ? "CHoCH" : "BOS"));
   stop = NormalizeDouble(stop, g_digits);
   target = (target > 0.0) ? NormalizeDouble(target, g_digits) : 0.0;

   bool sent = (direction > 0)
               ? g_trade.Buy(lot, _Symbol, 0.0, stop, target, comment)
               : g_trade.Sell(lot, _Symbol, 0.0, stop, target, comment);

   if(!sent)
   {
      PrintFormat("GTE V7: order failed, retcode %d (%s)",
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      // some brokers refuse the stops with the deal, send it naked and attach them after
      sent = (direction > 0) ? g_trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, comment)
                             : g_trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, comment);
      if(!sent)
         return;
   }

   g_tradesToday++;

   // find the position that was just opened and remember its original risk
   int direction_now = 0;
   if(CountOwnPositions(direction_now) > 0)
   {
      for(int index = PositionsTotal() - 1; index >= 0; index--)
      {
         ulong ticket = PositionGetTicket(index);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
            continue;
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         RememberRisk(ticket, openPrice, MathAbs(openPrice - stop));
         if(PositionGetDouble(POSITION_SL) <= 0.0 && stop > 0.0)
            g_trade.PositionModify(ticket, stop, target);
         PrintFormat("GTE V7: %s %s lots at %s | SL %s | TP %s | risk %s points",
                     (direction > 0 ? "BUY" : "SELL"), DoubleToString(lot, 2),
                     DoubleToString(openPrice, g_digits), DoubleToString(stop, g_digits),
                     (target > 0.0 ? DoubleToString(target, g_digits) : "trailing only"),
                     DoubleToString(risk / g_point, 0));
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| Chart objects                                                    |
//+------------------------------------------------------------------+
void DeleteOwnObjects(const string tag)
{
   string needle = g_prefix + tag;
   for(int index = ObjectsTotal(0, 0, -1) - 1; index >= 0; index--)
   {
      string name = ObjectName(0, index, 0, -1);
      if(StringFind(name, needle) == 0)
         ObjectDelete(0, name);
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
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectMove(0, name, 0, from, top);
   ObjectMove(0, name, 1, to, bottom);
}

void MakeMidLine(const string name, const datetime from, const datetime to,
                 const double price, const color clr)
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
      if(g_sigDir[index] > 0 && BarClose(shift) < bottom)
         return(true);
      if(g_sigDir[index] < 0 && BarClose(shift) > top)
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

   double atr = AtrValue(1);
   if(atr <= 0.0)
      atr = 10.0 * g_point;

   int drawn = 0;
   for(int index = g_sigCount - 1; index >= 0 && drawn < MaxDrawnSignals; index--)
   {
      int shift = g_sigShift[index];
      if(shift < 1 || shift >= g_ratesCount)
         continue;
      bool bullish = (g_sigDir[index] > 0);
      color mainColor = bullish ? BullColor : BearColor;
      string tail = IntegerToString(index) + "_" + IntegerToString((int)BarTime(shift));

      if(ShowSignals)
      {
         double level = bullish ? BarLow(shift) - atr * 0.35 : BarHigh(shift) + atr * 0.35;
         MakeArrow(g_prefix + "sig_a_" + tail, BarTime(shift),
                   bullish ? BarLow(shift) : BarHigh(shift), bullish ? 233 : 234, mainColor);
         MakeText(g_prefix + "sig_t_" + tail, BarTime(shift), level,
                  bullish ? "BULL" : "BEAR", mainColor, 8);
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
         if(zoneShift < 0 || zoneShift >= g_ratesCount)
            zoneShift = shift;
         datetime from = BarTime(zoneShift);
         datetime to = (datetime)(BarTime(0) + ZoneExtendBars * PeriodSeconds(PERIOD_CURRENT));
         color zoneColor = dead ? DeadZoneColor : (bullish ? BullZoneColor : BearZoneColor);
         double middle = (g_sigZoneTop[index] + g_sigZoneBot[index]) / 2.0;
         string caption = ShowZonePrice ? DoubleToString(middle, g_digits) : "";

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
      ObjectDelete(0, background);

   string header = (PanelLanguage == GTE_ARABIC) ? "نظرة السكالبينج" : "Scalping View";
   string columnTf = (PanelLanguage == GTE_ARABIC) ? "الفريم" : "Timeframe";
   string columnTrend = (PanelLanguage == GTE_ARABIC) ? "الاتجاه" : "Trend";

   MakePanelLabel(g_prefix + "panel_h0", PanelX + 20, PanelY, header, TextColor, PanelFontSize);
   MakePanelLabel(g_prefix + "panel_h1", PanelX + 120, PanelY + rowHeight, columnTf,
                  C'178,181,190', PanelFontSize);
   MakePanelLabel(g_prefix + "panel_h2", PanelX + 20, PanelY + rowHeight, columnTrend,
                  C'178,181,190', PanelFontSize);

   for(int row = 0; row < 6; row++)
   {
      int trend = TimeframeTrend(minutes[row], TrendSwingLength);
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
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(g_point <= 0.0)
      g_point = _Point;
   g_pointScale = (AutoScalePoints && (g_digits == 3 || g_digits == 5)) ? 10.0 : 1.0;

   if(SwingLength < 1 || TrendSwingLength < 1)
   {
      Print("GTE V7: the swing lengths must be 1 or more");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(ZoneLookback < 1 || ScanBars < 50)
   {
      Print("GTE V7: ZoneLookback must be >= 1 and ScanBars >= 50");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(PartialPercent < 0.0 || PartialPercent >= 100.0)
   {
      Print("GTE V7: PartialPercent must be between 0 and 99");
      return(INIT_PARAMETERS_INCORRECT);
   }

   ApplyPreset();

   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, AtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("GTE V7: cannot create the ATR handle");
      return(INIT_FAILED);
   }
   if(UseEmaFilter)
   {
      ENUM_TIMEFRAMES emaPeriodTf = NativePeriod(EmaMinutes);
      if(emaPeriodTf == PERIOD_CURRENT)
         emaPeriodTf = PERIOD_M5;
      g_emaHandle = iMA(_Symbol, emaPeriodTf, EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_emaHandle == INVALID_HANDLE)
         Print("GTE V7: cannot create the EMA handle, the EMA filter stays off");
   }

   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   g_trade.SetDeviationInPoints((ulong)SlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();

   g_prefix = "GTEv7_" + IntegerToString((int)MagicNumber) + "_";
   g_stateKey = "GTEv7_" + _Symbol + "_" + IntegerToString((int)MagicNumber);
   if(GlobalVariableCheck(g_stateKey))
      g_handledSignal = (datetime)GlobalVariableGet(g_stateKey);
   else
   {
      datetime times[];
      if(CopyTime(_Symbol, PERIOD_CURRENT, 1, 1, times) > 0)
         g_handledSignal = times[0];   // do not fire on a signal that is already history
   }

   ResetDailyCounter();
   g_lastBarTime = 0;

   PrintFormat("GTE V7 MT5 started on %s, preset %d, stop mode %d, trailing %d%s",
               _Symbol, (int)Preset, (int)g_stopMode, (int)g_trailMode,
               (TradeEnabled ? "" : " (drawing only)"));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_emaHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaHandle);
   DeleteOwnObjects("");
   ChartRedraw(0);
}

void OnTick()
{
   // trailing and profit locking work on every tick and need no bar history
   ManageAllPositions();

   datetime current[];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, 1, current) <= 0)
      return;
   if(current[0] == g_lastBarTime)
      return;                  // the structure is only re-read once per bar

   if(!LoadRates())
      return;
   if(g_ratesCount < g_swingLength * 2 + 20)
      return;
   g_lastBarTime = current[0];

   ScanStructure();
   DrawSignals();
   DrawPanel();
   ChartRedraw(0);
   TryTrade();
}
//+------------------------------------------------------------------+
