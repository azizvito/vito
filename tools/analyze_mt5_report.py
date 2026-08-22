#!/usr/bin/env python3
"""Measure how good an MT5 Strategy Tester result really is.

The tester gives you a win rate and a profit factor, but those numbers say
nothing on their own: 70% wins over 30 trades is noise, and a profit factor of
1.4 can easily be a losing system once the confidence interval is drawn.

This script reads a Strategy Tester report and answers three questions:

    1. what are the real numbers (win rate, profit factor, expectancy, drawdown)
    2. how uncertain are they (Wilson interval, bootstrap of the trade sequence)
    3. is the test itself trustworthy (modelling quality, spread, sample size)

Accepted inputs
---------------
    * the HTML report      : Strategy Tester -> right click -> Report -> HTML
    * a csv / tsv export   : any table with a profit column
    * a plain list of numbers, one trade result per line (copy of the profit column)

Usage
-----
    python3 tools/analyze_mt5_report.py report.html
    python3 tools/analyze_mt5_report.py --lang en report.html
    cat profits.txt | python3 tools/analyze_mt5_report.py -
    python3 tools/analyze_mt5_report.py --selftest
"""

from __future__ import annotations

import argparse
import csv
import io
import math
import random
import re
import sys
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path

# --------------------------------------------------------------------------- text

NUMBER = re.compile(r"^-?[\d\u00a0\u202f ,.']+$")

AR = {
    "title": "تقييم نتيجة الباك تست",
    "sample": "حجم العينة",
    "trades": "عدد الصفقات",
    "wins": "الصفقات الرابحة",
    "losses": "الصفقات الخاسرة",
    "win_rate": "نسبة النجاح",
    "win_ci": "المجال الحقيقي لنسبة النجاح (ثقة 95%)",
    "net": "صافي الربح",
    "gross_profit": "إجمالي الأرباح",
    "gross_loss": "إجمالي الخسائر",
    "pf": "معامل الربح (Profit Factor)",
    "pf_ci": "مجال معامل الربح (ثقة 95%)",
    "expectancy": "متوسط الربح للصفقة",
    "avg_win": "متوسط الصفقة الرابحة",
    "avg_loss": "متوسط الصفقة الخاسرة",
    "payoff": "نسبة الربح للخسارة",
    "streak": "أطول سلسلة خسائر متتالية",
    "drawdown": "أقصى تراجع (من منحنى الصفقات)",
    "recovery": "معامل الاسترداد",
    "span": "فترة الاختبار",
    "quality": "جودة النمذجة",
    "spread": "السبريد",
    "verdict": "الحكم",
    "warnings": "تحذيرات",
    "notes": "ملاحظات",
}

EN = {
    "title": "Backtest quality report",
    "sample": "Sample",
    "trades": "Trades",
    "wins": "Winners",
    "losses": "Losers",
    "win_rate": "Win rate",
    "win_ci": "True win rate (95% confidence)",
    "net": "Net profit",
    "gross_profit": "Gross profit",
    "gross_loss": "Gross loss",
    "pf": "Profit factor",
    "pf_ci": "Profit factor (95% confidence)",
    "expectancy": "Expectancy per trade",
    "avg_win": "Average winner",
    "avg_loss": "Average loser",
    "payoff": "Payoff ratio",
    "streak": "Longest losing streak",
    "drawdown": "Max drawdown (trade curve)",
    "recovery": "Recovery factor",
    "span": "Tested period",
    "quality": "Modelling quality",
    "spread": "Spread",
    "verdict": "Verdict",
    "warnings": "Warnings",
    "notes": "Notes",
}


def to_number(text: str) -> float | None:
    raw = (text or "").strip()
    if not raw or not NUMBER.match(raw):
        return None
    cleaned = raw.replace("\u00a0", "").replace("\u202f", "").replace(" ", "").replace("'", "")
    if "," in cleaned and "." in cleaned:
        cleaned = cleaned.replace(",", "")          # 1,234.56
    elif cleaned.count(",") == 1 and len(cleaned.split(",")[-1]) in (1, 2):
        cleaned = cleaned.replace(",", ".")         # 1234,56
    else:
        cleaned = cleaned.replace(",", "")
    try:
        return float(cleaned)
    except ValueError:
        return None


# --------------------------------------------------------------------------- input

class TableReader(HTMLParser):
    """Collect every table row of the document as a list of cell strings."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[list[str]] = []
        self._row: list[str] | None = None
        self._cell: list[str] | None = None

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag == "tr":
            self._row = []
        elif tag in ("td", "th"):
            self._cell = []
        elif tag == "br" and self._cell is not None:
            self._cell.append(" ")

    def handle_endtag(self, tag: str) -> None:
        if tag in ("td", "th") and self._cell is not None:
            text = " ".join("".join(self._cell).split())
            if self._row is None:
                self._row = []
            self._row.append(text)
            self._cell = None
        elif tag == "tr" and self._row is not None:
            if any(cell for cell in self._row):
                self.rows.append(self._row)
            self._row = None

    def handle_data(self, data: str) -> None:
        if self._cell is not None:
            self._cell.append(data)


@dataclass
class Trade:
    profit: float
    opened: str = ""
    closed: str = ""
    side: str = ""
    volume: float = 0.0
    open_price: float | None = None
    close_price: float | None = None
    stop: float | None = None

    @property
    def r_multiple(self) -> float | None:
        if self.open_price is None or self.close_price is None or not self.stop:
            return None
        risk = abs(self.open_price - self.stop)
        if risk <= 0:
            return None
        direction = 1.0 if self.side.lower().startswith("b") else -1.0
        return (self.close_price - self.open_price) * direction / risk


@dataclass
class Source:
    trades: list[Trade] = field(default_factory=list)
    summary: dict[str, str] = field(default_factory=dict)
    origin: str = ""
    notes: list[str] = field(default_factory=list)


SUMMARY_KEYS = {
    "total net profit": "net_profit",
    "gross profit": "gross_profit",
    "gross loss": "gross_loss",
    "profit factor": "profit_factor",
    "expected payoff": "expected_payoff",
    "recovery factor": "recovery_factor",
    "sharpe ratio": "sharpe",
    "total trades": "total_trades",
    "modelling quality": "quality",
    "modeling quality": "quality",
    "bars": "bars",
    "ticks": "ticks",
    "symbol": "symbol",
    "period": "period",
    "spread": "spread",
    "initial deposit": "deposit",
    "balance drawdown maximal": "balance_dd",
    "equity drawdown maximal": "equity_dd",
    "profit trades (% of total)": "profit_trades",
    "loss trades (% of total)": "loss_trades",
    "maximum consecutive losses ($)": "max_consecutive_losses",
    "maximal consecutive loss (count)": "maximal_consecutive_loss",
}

# a few Arabic labels of the same report, MT5 translates the summary
SUMMARY_KEYS_AR = {
    "إجمالي صافي الربح": "net_profit",
    "الربح الإجمالي": "gross_profit",
    "الخسارة الإجمالية": "gross_loss",
    "عامل الربح": "profit_factor",
    "معامل الربح": "profit_factor",
    "الربح المتوقع": "expected_payoff",
    "معامل الاسترداد": "recovery_factor",
    "إجمالي الصفقات": "total_trades",
    "جودة النمذجة": "quality",
    "الرمز": "symbol",
    "الفترة": "period",
    "الإيداع الأولي": "deposit",
}


def canonical_key(label: str) -> str | None:
    text = label.strip().rstrip(":").strip()
    lowered = text.lower()
    if lowered in SUMMARY_KEYS:
        return SUMMARY_KEYS[lowered]
    if text in SUMMARY_KEYS_AR:
        return SUMMARY_KEYS_AR[text]
    for known, key in SUMMARY_KEYS.items():
        if lowered.startswith(known):
            return key
    return None


def _looks_like_time(cell: str) -> bool:
    return bool(re.match(r"^\d{4}[.\-/]\d{2}[.\-/]\d{2}", cell.strip()))


def parse_html(text: str) -> Source:
    reader = TableReader()
    reader.feed(text)
    source = Source(origin="html")

    # ---- summary: cells that end with ':' are followed by their value
    for row in reader.rows:
        for index, cell in enumerate(row[:-1]):
            if not cell.endswith(":"):
                continue
            key = canonical_key(cell)
            if key and key not in source.summary:
                source.summary[key] = row[index + 1]

    # ---- find the widest table whose header mentions a profit column
    header_index = -1
    profit_column = -1
    for position, row in enumerate(reader.rows):
        lowered = [cell.strip().lower() for cell in row]
        has_profit = any(cell in ("profit", "الربح", "profit/loss") for cell in lowered)
        has_time = any(cell in ("time", "الوقت", "open time") for cell in lowered)
        if has_profit and has_time and len(row) >= 6:
            header_index = position
            profit_column = max(
                idx for idx, cell in enumerate(lowered)
                if cell in ("profit", "الربح", "profit/loss")
            )
            break

    if header_index < 0:
        source.notes.append("no trade table found, only the summary was read")
        return source

    header = [cell.strip().lower() for cell in reader.rows[header_index]]
    width = len(header)

    def column(*names: str) -> int:
        for name in names:
            if name in header:
                return header.index(name)
        return -1

    type_column = column("type", "النوع")
    volume_column = column("volume", "الحجم", "size")
    direction_column = column("direction", "الاتجاه")
    stop_column = column("s / l", "s/l", "sl", "stop loss")
    # the report repeats "time" and "price" for the open and the close of a position
    time_columns = [index for index, cell in enumerate(header) if cell in ("time", "الوقت")]
    price_columns = [index for index, cell in enumerate(header) if cell in ("price", "السعر")]

    partial_rows = 0
    for row in reader.rows[header_index + 1:]:
        if len(row) < width or not _looks_like_time(row[0]):
            continue
        profit = to_number(row[profit_column]) if profit_column < len(row) else None
        if profit is None:
            continue
        if direction_column >= 0:
            direction = row[direction_column].strip().lower()
            if direction in ("in", "داخل"):
                continue                        # opening deal, it carries no result
            if direction in ("in/out", "داخل/خارج"):
                partial_rows += 1

        trade = Trade(profit=profit)
        trade.opened = row[time_columns[0]] if time_columns else row[0]
        if len(time_columns) > 1:
            trade.closed = row[time_columns[1]]
        if type_column >= 0:
            trade.side = row[type_column]
        if volume_column >= 0:
            trade.volume = to_number(row[volume_column]) or 0.0
        if price_columns:
            trade.open_price = to_number(row[price_columns[0]])
            if len(price_columns) > 1:
                trade.close_price = to_number(row[price_columns[1]])
        if stop_column >= 0:
            trade.stop = to_number(row[stop_column])
        source.trades.append(trade)

    if partial_rows:
        source.notes.append(
            f"{partial_rows} row(s) are partial closes, they are counted as separate results"
        )
    return source


def parse_table_text(text: str) -> Source:
    """csv / tsv export, or a bare list of numbers."""

    source = Source(origin="text")
    stripped = [line for line in text.splitlines() if line.strip()]
    if not stripped:
        return source

    numbers_only = [to_number(line) for line in stripped]
    if all(value is not None for value in numbers_only):
        source.trades = [Trade(profit=float(value)) for value in numbers_only if value is not None]
        source.origin = "list of results"
        return source

    sample = "\n".join(stripped[:50])
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=",;\t|")
        delimiter = dialect.delimiter
    except csv.Error:
        delimiter = "\t" if "\t" in sample else ","

    rows = list(csv.reader(io.StringIO(text), delimiter=delimiter))
    rows = [row for row in rows if any(cell.strip() for cell in row)]
    if not rows:
        return source

    header = [cell.strip().lower() for cell in rows[0]]
    profit_column = -1
    for index, cell in enumerate(header):
        if cell in ("profit", "الربح", "profit/loss", "net", "result"):
            profit_column = index
    body = rows[1:] if profit_column >= 0 else rows

    if profit_column < 0:
        # take the last column that parses as a number on most rows
        counts: dict[int, int] = {}
        for row in body:
            for index, cell in enumerate(row):
                if to_number(cell) is not None:
                    counts[index] = counts.get(index, 0) + 1
        if not counts:
            return source
        profit_column = max(counts, key=lambda key: (counts[key], key))
        source.notes.append(f"column {profit_column + 1} was used as the result column")

    for row in body:
        if profit_column >= len(row):
            continue
        value = to_number(row[profit_column])
        if value is None:
            continue
        source.trades.append(Trade(profit=value))
    source.origin = "table"
    return source


def load(text: str) -> Source:
    lowered = text[:4000].lower()
    if "<html" in lowered or "<table" in lowered or "<tr" in lowered:
        return parse_html(text)
    return parse_table_text(text)


# ----------------------------------------------------------------------- statistics

def wilson_interval(wins: int, total: int, z: float = 1.96) -> tuple[float, float]:
    if total <= 0:
        return (0.0, 0.0)
    phat = wins / total
    denominator = 1 + z * z / total
    centre = phat + z * z / (2 * total)
    spread = z * math.sqrt(phat * (1 - phat) / total + z * z / (4 * total * total))
    return ((centre - spread) / denominator, (centre + spread) / denominator)


def profit_factor(results: list[float]) -> float:
    gains = sum(value for value in results if value > 0)
    losses = -sum(value for value in results if value < 0)
    if losses <= 0:
        return math.inf if gains > 0 else 0.0
    return gains / losses


def bootstrap_interval(results: list[float], rounds: int, seed: int = 12345) -> dict[str, tuple[float, float]]:
    if len(results) < 5:
        return {}
    rng = random.Random(seed)
    size = len(results)
    factors: list[float] = []
    expectancies: list[float] = []
    for _ in range(rounds):
        sample = [results[rng.randrange(size)] for _ in range(size)]
        factor = profit_factor(sample)
        if math.isfinite(factor):
            factors.append(factor)
        expectancies.append(sum(sample) / size)
    factors.sort()
    expectancies.sort()

    def interval(values: list[float]) -> tuple[float, float]:
        if not values:
            return (0.0, 0.0)
        low = values[max(0, int(0.025 * len(values)) - 1)]
        high = values[min(len(values) - 1, int(0.975 * len(values)))]
        return (low, high)

    return {"profit_factor": interval(factors), "expectancy": interval(expectancies)}


def max_drawdown(results: list[float]) -> tuple[float, float]:
    """Drawdown of the closed trade curve: absolute and percent of the peak."""

    equity = 0.0
    peak = 0.0
    worst = 0.0
    worst_relative = 0.0
    for value in results:
        equity += value
        peak = max(peak, equity)
        gap = peak - equity
        if gap > worst:
            worst = gap
            worst_relative = gap / peak * 100 if peak > 0 else 0.0
    return worst, worst_relative


def longest_losing_streak(results: list[float]) -> int:
    longest = 0
    current = 0
    for value in results:
        if value < 0:
            current += 1
            longest = max(longest, current)
        else:
            current = 0
    return longest


@dataclass
class Analysis:
    trades: int = 0
    wins: int = 0
    losses: int = 0
    win_rate: float = 0.0
    win_low: float = 0.0
    win_high: float = 0.0
    net: float = 0.0
    gross_profit: float = 0.0
    gross_loss: float = 0.0
    pf: float = 0.0
    pf_low: float = 0.0
    pf_high: float = 0.0
    expectancy: float = 0.0
    expectancy_low: float = 0.0
    expectancy_high: float = 0.0
    avg_win: float = 0.0
    avg_loss: float = 0.0
    payoff: float = 0.0
    streak: int = 0
    drawdown: float = 0.0
    drawdown_pct: float = 0.0
    recovery: float = 0.0
    r_values: list[float] = field(default_factory=list)


def analyse(trades: list[Trade], rounds: int = 4000) -> Analysis:
    results = [trade.profit for trade in trades]
    out = Analysis()
    out.trades = len(results)
    if not results:
        return out

    winners = [value for value in results if value > 0]
    losers = [value for value in results if value < 0]
    out.wins = len(winners)
    out.losses = len(losers)
    out.win_rate = out.wins / out.trades * 100
    out.win_low, out.win_high = [value * 100 for value in wilson_interval(out.wins, out.trades)]
    out.gross_profit = sum(winners)
    out.gross_loss = -sum(losers)
    out.net = sum(results)
    out.pf = profit_factor(results)
    out.expectancy = out.net / out.trades
    out.avg_win = (sum(winners) / len(winners)) if winners else 0.0
    out.avg_loss = (sum(losers) / len(losers)) if losers else 0.0
    out.payoff = abs(out.avg_win / out.avg_loss) if out.avg_loss else math.inf
    out.streak = longest_losing_streak(results)
    out.drawdown, out.drawdown_pct = max_drawdown(results)
    out.recovery = out.net / out.drawdown if out.drawdown > 0 else math.inf

    intervals = bootstrap_interval(results, rounds)
    if intervals:
        out.pf_low, out.pf_high = intervals["profit_factor"]
        out.expectancy_low, out.expectancy_high = intervals["expectancy"]

    out.r_values = [value for value in (trade.r_multiple for trade in trades) if value is not None]
    return out


# -------------------------------------------------------------------------- verdict

def build_verdict(analysis: Analysis, summary: dict[str, str], arabic: bool) -> tuple[list[str], list[str]]:
    verdict: list[str] = []
    warnings: list[str] = []

    if analysis.trades == 0:
        verdict.append("لا توجد صفقات في البيانات" if arabic else "no trades in the data")
        return verdict, warnings

    # sample size
    if analysis.trades < 30:
        warnings.append(
            f"عدد الصفقات {analysis.trades} صغير جداً، أي نسبة نجاح هنا مجرد حظ"
            if arabic else
            f"{analysis.trades} trades is far too few, the win rate is noise"
        )
    elif analysis.trades < 100:
        warnings.append(
            f"عدد الصفقات {analysis.trades} قليل، النتيجة مؤشر مبدئي وليس دليلاً"
            if arabic else
            f"{analysis.trades} trades is a small sample, treat the result as a hint"
        )

    # is it profitable at all
    if analysis.net <= 0:
        verdict.append(
            "البوت خاسر على هذه البيانات، لا داعي لقياس نسبة النجاح"
            if arabic else
            "the bot lost money on this data"
        )
    elif analysis.expectancy_low > 0 and analysis.pf_low > 1.0:
        verdict.append(
            "رابح، وحتى الحد الأدنى للثقة 95% يبقى رابحاً — هذه أقوى نتيجة ممكنة من عينة واحدة"
            if arabic else
            "profitable, and still profitable at the lower 95% bound"
        )
    elif analysis.pf_low > 0 and analysis.pf_low <= 1.0:
        verdict.append(
            f"رابح في هذه العينة، لكن مجال الثقة ينزل إلى {analysis.pf_low:.2f} "
            "أي أن كونه رابحاً غير مثبت بعد"
            if arabic else
            f"profitable here, but the confidence interval reaches {analysis.pf_low:.2f}, so it is not proven"
        )
    else:
        verdict.append("رابح في هذه العينة" if arabic else "profitable on this sample")

    # win rate reading
    if analysis.trades >= 30:
        verdict.append(
            f"نسبة النجاح الحقيقية تقع بين {analysis.win_low:.1f}% و {analysis.win_high:.1f}% "
            f"(المقاسة {analysis.win_rate:.1f}%)"
            if arabic else
            f"the true win rate sits between {analysis.win_low:.1f}% and {analysis.win_high:.1f}% "
            f"(measured {analysis.win_rate:.1f}%)"
        )

    # win rate versus payoff
    if math.isfinite(analysis.payoff) and analysis.payoff > 0:
        break_even = 100 / (1 + analysis.payoff)
        margin = analysis.win_rate - break_even
        verdict.append(
            f"نسبة التعادل المطلوبة لهذه النسبة بين الربح والخسارة هي {break_even:.1f}%، "
            f"والفارق لديك {margin:+.1f} نقطة مئوية"
            if arabic else
            f"break even win rate for this payoff is {break_even:.1f}%, your margin is {margin:+.1f} points"
        )
        if analysis.win_low < break_even:
            warnings.append(
                "الحد الأدنى لمجال نسبة النجاح أقل من نسبة التعادل، أي أن العينة لا تنفي الخسارة"
                if arabic else
                "the lower bound of the win rate is under break even, losing is not excluded"
            )

    # risk of ruin style reading
    if analysis.streak >= 6:
        warnings.append(
            f"أطول سلسلة خسائر {analysis.streak} صفقة، احسب هل يتحمّلها رصيدك بالمخاطرة الحالية"
            if arabic else
            f"longest losing streak is {analysis.streak}, check your account can take it"
        )
    if analysis.drawdown > 0 and math.isfinite(analysis.recovery) and analysis.recovery < 2:
        warnings.append(
            f"معامل الاسترداد {analysis.recovery:.2f} منخفض: الربح لا يبرّر حجم التراجع"
            if arabic else
            f"recovery factor {analysis.recovery:.2f} is low, profit does not justify the drawdown"
        )

    # test quality
    quality = summary.get("quality", "")
    quality_value = to_number(quality.replace("%", "")) if quality else None
    if quality_value is not None and quality_value < 90:
        warnings.append(
            f"جودة النمذجة {quality_value:.0f}% فقط، أعد الاختبار بنموذج Every tick based on real ticks"
            if arabic else
            f"modelling quality is only {quality_value:.0f}%, retest with real ticks"
        )
    spread = summary.get("spread", "")
    if spread and re.match(r"^\d+$", spread.strip()):
        warnings.append(
            f"السبريد في الاختبار ثابت ({spread})، اختبر بسبريد الوسيط الحقيقي"
            if arabic else
            f"the test used a fixed spread ({spread}), retest with the real one"
        )

    return verdict, warnings


# --------------------------------------------------------------------------- output

def money(value: float) -> str:
    if not math.isfinite(value):
        return "∞"
    return f"{value:,.2f}"


def render(analysis: Analysis, source: Source, arabic: bool) -> str:
    words = AR if arabic else EN
    lines: list[str] = []
    lines.append("=" * 62)
    lines.append(words["title"])
    lines.append("=" * 62)

    summary = source.summary
    if summary.get("symbol") or summary.get("period"):
        lines.append(f"{words['span']:<38} {summary.get('symbol', '?')} {summary.get('period', '')}".rstrip())
    if summary.get("quality"):
        lines.append(f"{words['quality']:<38} {summary['quality']}")
    if summary.get("spread"):
        lines.append(f"{words['spread']:<38} {summary['spread']}")

    rows = [
        (words["trades"], f"{analysis.trades}"),
        (words["wins"], f"{analysis.wins}"),
        (words["losses"], f"{analysis.losses}"),
        (words["win_rate"], f"{analysis.win_rate:.2f} %"),
        (words["win_ci"], f"{analysis.win_low:.1f} % .. {analysis.win_high:.1f} %"),
        (words["net"], money(analysis.net)),
        (words["gross_profit"], money(analysis.gross_profit)),
        (words["gross_loss"], money(analysis.gross_loss)),
        (words["pf"], f"{analysis.pf:.3f}"),
        (words["pf_ci"], f"{analysis.pf_low:.3f} .. {analysis.pf_high:.3f}"),
        (words["expectancy"], money(analysis.expectancy)),
        (words["avg_win"], money(analysis.avg_win)),
        (words["avg_loss"], money(analysis.avg_loss)),
        (words["payoff"], f"{analysis.payoff:.3f}" if math.isfinite(analysis.payoff) else "∞"),
        (words["streak"], f"{analysis.streak}"),
        (words["drawdown"], f"{money(analysis.drawdown)} ({analysis.drawdown_pct:.1f} %)"),
        (words["recovery"], f"{analysis.recovery:.2f}" if math.isfinite(analysis.recovery) else "∞"),
    ]
    lines.append("-" * 62)
    for label, value in rows:
        lines.append(f"{label:<38} {value}")

    if analysis.r_values:
        average_r = sum(analysis.r_values) / len(analysis.r_values)
        lines.append(f"{'متوسط R' if arabic else 'Average R':<38} {average_r:+.3f}"
                     f"  ({len(analysis.r_values)} {'صفقة' if arabic else 'trades'})")

    verdict, warnings = build_verdict(analysis, summary, arabic)
    lines.append("-" * 62)
    lines.append(words["verdict"] + ":")
    for item in verdict:
        lines.append(f"  - {item}")
    if warnings:
        lines.append(words["warnings"] + ":")
        for item in warnings:
            lines.append(f"  ! {item}")
    if source.notes:
        lines.append(words["notes"] + ":")
        for item in source.notes:
            lines.append(f"  * {item}")
    lines.append("=" * 62)
    return "\n".join(lines)


# -------------------------------------------------------------------------- selftest

SAMPLE_REPORT = """
<html><body>
<table>
<tr><td>Symbol:</td><td>XAUUSD</td><td>Period:</td><td>M1 2026.01.01 - 2026.03.01</td></tr>
<tr><td>Modelling quality:</td><td>99.90%</td><td>Spread:</td><td>Current</td></tr>
<tr><td>Total Net Profit:</td><td>1 200.00</td><td>Gross Profit:</td><td>3 000.00</td>
    <td>Gross Loss:</td><td>-1 800.00</td></tr>
<tr><td>Profit Factor:</td><td>1.67</td><td>Expected Payoff:</td><td>12.00</td></tr>
</table>
<table>
<tr><th>Time</th><th>Position</th><th>Symbol</th><th>Type</th><th>Volume</th><th>Price</th>
    <th>S / L</th><th>T / P</th><th>Time</th><th>Price</th><th>Commission</th><th>Swap</th>
    <th>Profit</th></tr>
<tr><td>2026.01.02 10:00:00</td><td>1</td><td>XAUUSD</td><td>buy</td><td>0.10</td><td>4300.00</td>
    <td>4299.40</td><td>4300.90</td><td>2026.01.02 10:20:00</td><td>4300.90</td><td>0.00</td>
    <td>0.00</td><td>9.00</td></tr>
<tr><td>2026.01.02 12:00:00</td><td>2</td><td>XAUUSD</td><td>sell</td><td>0.10</td><td>4310.00</td>
    <td>4310.60</td><td>4309.10</td><td>2026.01.02 12:30:00</td><td>4310.60</td><td>0.00</td>
    <td>0.00</td><td>-6.00</td></tr>
<tr><td>2026.01.03 09:00:00</td><td>3</td><td>XAUUSD</td><td>buy</td><td>0.10</td><td>4320.00</td>
    <td>4319.40</td><td>4320.90</td><td>2026.01.03 09:40:00</td><td>4320.90</td><td>0.00</td>
    <td>0.00</td><td>9.00</td></tr>
<tr><td>2026.01.03 14:00:00</td><td>4</td><td>XAUUSD</td><td>buy</td><td>0.10</td><td>4325.00</td>
    <td>4324.40</td><td>4325.90</td><td>2026.01.03 14:15:00</td><td>4324.40</td><td>0.00</td>
    <td>0.00</td><td>-6.00</td></tr>
</table>
</body></html>
"""


def selftest() -> int:
    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    # ---- html report
    source = load(SAMPLE_REPORT)
    check(len(source.trades) == 4, f"expected 4 trades, parsed {len(source.trades)}")
    check(source.summary.get("symbol") == "XAUUSD", "symbol not read from the summary")
    check(source.summary.get("quality") == "99.90%", "modelling quality not read")
    analysis = analyse(source.trades, rounds=500)
    check(analysis.wins == 2 and analysis.losses == 2, "win / loss split is wrong")
    check(abs(analysis.win_rate - 50.0) < 1e-9, "win rate is wrong")
    check(abs(analysis.net - 6.0) < 1e-9, f"net profit is wrong: {analysis.net}")
    check(abs(analysis.pf - 1.5) < 1e-9, f"profit factor is wrong: {analysis.pf}")
    check(abs(analysis.expectancy - 1.5) < 1e-9, "expectancy is wrong")
    check(analysis.streak == 1, f"losing streak is wrong: {analysis.streak}")
    check(len(analysis.r_values) == 4, f"R multiples not computed: {analysis.r_values}")
    # trade 1: buy 4300 -> 4300.90 with a stop at 4299.40, risk 0.60, reward 0.90 = 1.5R
    check(abs(analysis.r_values[0] - 1.5) < 1e-6, f"R of the first trade is wrong: {analysis.r_values[0]}")
    check(abs(analysis.r_values[1] - (-1.0)) < 1e-6, f"R of the sell is wrong: {analysis.r_values[1]}")

    # ---- plain list of results
    listed = load("10\n-5\n7.5\n-5\n-5\n20\n")
    check(len(listed.trades) == 6, f"list input parsed {len(listed.trades)} rows")
    # curve: 10, 5, 12.5, 7.5, 2.5, 22.5 -> two losses in a row, worst dip 12.5 -> 2.5
    listed_analysis = analyse(listed.trades, rounds=200)
    check(listed_analysis.streak == 2, f"streak from list is wrong: {listed_analysis.streak}")
    check(abs(listed_analysis.net - 22.5) < 1e-9, "net from list is wrong")
    check(abs(listed_analysis.drawdown - 10.0) < 1e-9, f"drawdown is wrong: {listed_analysis.drawdown}")

    # ---- csv export
    csv_text = "Time,Type,Volume,Profit\n2026.01.02,buy,0.1,12.5\n2026.01.03,sell,0.1,-4.0\n"
    table = load(csv_text)
    check(len(table.trades) == 2, f"csv parsed {len(table.trades)} rows")
    check(abs(table.trades[0].profit - 12.5) < 1e-9, "csv profit column misread")

    # ---- number formats
    check(to_number("1 234,56") == 1234.56, "european format misread")
    check(to_number("1,234.56") == 1234.56, "us format misread")
    check(to_number("-1\u00a0800.00") == -1800.0, "nbsp format misread")
    check(to_number("abc") is None, "text should not parse as a number")

    # ---- statistics sanity
    low, high = wilson_interval(15, 30)
    check(low < 0.5 < high, "wilson interval does not contain the estimate")
    check(high - low > 0.3, "wilson interval on 30 trades should be wide")
    low_big, high_big = wilson_interval(500, 1000)
    check(high_big - low_big < 0.08, "wilson interval on 1000 trades should be narrow")

    # a losing system must be reported as losing
    losing = analyse([Trade(profit=value) for value in ([-10] * 6 + [8] * 4)], rounds=200)
    verdict, _ = build_verdict(losing, {}, arabic=False)
    check(any("lost money" in line for line in verdict), f"losing system not detected: {verdict}")

    if failures:
        print("SELFTEST FAILED")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("selftest ok: html, csv and list inputs, statistics and verdict all behave")
    return 0


# ------------------------------------------------------------------------------ cli

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Measure the real quality of an MT5 Strategy Tester result"
    )
    parser.add_argument("input", nargs="?", help="report file, or - to read stdin")
    parser.add_argument("--lang", choices=["ar", "en"], default="ar")
    parser.add_argument("--bootstrap", type=int, default=4000, help="bootstrap rounds")
    parser.add_argument("--selftest", action="store_true", help="run the built in checks")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.input:
        parser.error("give a report file, or - to read from stdin")

    text = sys.stdin.read() if args.input == "-" else Path(args.input).read_text(
        encoding="utf-8", errors="replace"
    )
    source = load(text)
    if not source.trades and not source.summary:
        print("could not read any trades or summary from this input")
        return 1

    analysis = analyse(source.trades, rounds=args.bootstrap)
    print(render(analysis, source, arabic=args.lang == "ar"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
