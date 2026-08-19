# GTE+OF+OB — مؤشر TradingView

إعادة بناء بصرية لمؤشر **GTE+OF+OB / GTE V7** الظاهر في لقطات الشاشة: إشارات BULL/BEAR، Order Blocks، مناطق IMB، وجدول اتجاه الفريمات.

> هذا سكربت أصلي مستوحى من الشكل الظاهر على الشارت، وليس نسخة حرفية من كود تجاري مغلق. المنطق الداخلي لأي مؤشر مدفوع لا يمكن استنساخه 100% بدون المصدر.

## الملفات

| ملف | الوصف |
|-----|--------|
| `GTE_OF_OB.pine` | المؤشر الرئيسي (Overlay) على TradingView |
| `GTE_OF_OB_Strategy.pine` | نسخة Strategy للاختبار الخلفي على TradingView |
| `GTE_OF_OB_EA.mq4` | بوت تداول (Expert Advisor) لمنصة **MT4** |

## التثبيت في TradingView

1. افتح [TradingView Pine Editor](https://www.tradingview.com/pine-editor/)
2. انسخ محتوى `GTE_OF_OB.pine` بالكامل
3. اضغط **Save** ثم **Add to chart**
4. للباك تست: انسخ `GTE_OF_OB_Strategy.pine` كـ Strategy

## ما يظهر على الشارت

- تسميات **BULL** (أخضر) و **BEAR** (أحمر) على القيعان/القمم المحورية
- أسهم + نقاط على الشموع
- رسائل **Close SELL on BULL** / **Close BUY on BEAR**
- صناديق **Order Blocks** خضراء/حمراء مع خطوط أفقية وسعر
- مناطق **IMB** (Fair Value Gap)
- جدول **اتجاه الفريمات | تداول السكالب** أعلى اليمين: 1m / 3m / 5m / 10m / 15m / 25m
- تلوين الشموع حسب الاتجاه
- تنبيهات Alert لـ BULL و BEAR

## إعدادات افتراضية (مطابقة تقريباً لسطر الحالة في الصور)

`8 21 14 7 6 2 5 … 1.35 0.6 … 0.18 … Wick`

يمكنك تعديل كل القيم من إعدادات المؤشر (⚙️).

## اقتراحات ضبط على الذهب (XAUUSD)

- فريم السكالب: `15s` / `1m` / `2m` / `5m`
- إذا كثرت الإشارات: زد `Min Bars Between Signals` أو `Pivot Left Bars`
- إذا قلت الإشارات: خفّض `Min Pivot ATR Mult` وعطّل `Require Trend Alignment`
- للعربية في الجدول: فعّل **Arabic Labels**

## بوت MT4 (`GTE_OF_OB_EA.mq4`)

يفتح صفقات تلقائياً على إشارات BULL/BEAR بنفس منطق الـ pivots + EMA/RSI، مع:

- Stop Loss / Take Profit حسب ATR (افتراضي SL 0.6× و TP 1.35×)
- إغلاق الصفقة المعاكسة عند إشارة جديدة (Close on flip)
- لوت ثابت أو نسبة مخاطرة من الرصيد
- فلتر اختياري لفريمات أعلى (MTF)
- أسهم ووسوم BULL/BEAR على الشارت + لوحة حالة

### التثبيت على MT4

1. انسخ `GTE_OF_OB_EA.mq4` إلى مجلد:  
   `File → Open Data Folder → MQL4 → Experts`
2. في MetaEditor اضغط **Compile** (F7)
3. في MT4: من Navigator اسحب البوت على الشارت (مثل XAUUSD M1/M5)
4. فعّل **AutoTrading** واختبر على حساب Demo أولاً

### إعدادات مهمة للذهب

- `InpLots` أو `InpRiskPercent` (مثلاً 1%)
- `InpMaxSpreadPts` حسب الوسيط
- `InpUseMtfFilter=true` مع `InpMtfTf=PERIOD_M5` لتقليل الإشارات العكسية

## تنبيه

المؤشرات والبوتات لا تضمن أرباحاً. اختبر على حساب تجريبي أولاً، وراجع الرافعة والسبريد على الذهب بحذر.
