#!/usr/bin/env python3
"""Prove that the MQL4 engine and the Pine engine find the same signals.

MetaTrader indexes bars backwards (``High[0]`` is the newest bar) while Pine
indexes them forwards, and the MQL4 file walks the history with
``candidate = shift + SwingLength``. That arithmetic is the easiest thing to get
wrong, and a wrong pivot offset would silently shift every signal.

This script implements both readings of the same rules and compares them:

  * ``forward_signals``  - the Pine reading, oldest bar first, index 0 = oldest
  * ``mt4_signals``      - the MQL4 reading, shift 0 = newest bar

Run it after touching either engine:

    python3 tools/verify_engine_parity.py
"""

from __future__ import annotations

import random
import sys

Bar = tuple[float, float, float, float]  # open, high, low, close


# ----------------------------------------------------------------- test data
def make_bars(count: int, seed: int) -> list[Bar]:
    rng = random.Random(seed)
    price = 4300.0
    drift = 0.0
    bars: list[Bar] = []
    for index in range(count):
        if index % 90 == 0:
            drift = rng.uniform(-0.35, 0.35)
        open_price = price
        price = price + drift + rng.gauss(0.0, 0.8)
        high = max(open_price, price) + abs(rng.gauss(0.0, 0.4))
        low = min(open_price, price) - abs(rng.gauss(0.0, 0.4))
        bars.append((open_price, high, low, price))
    return bars


# ------------------------------------------------------- Pine style, forward
def forward_signals(bars: list[Bar], swing: int, shift_only: bool, use_close: bool,
                    zone_lookback: int) -> list[tuple[int, int, bool, float, float]]:
    total = len(bars)
    highs = [bar[1] for bar in bars]
    lows = [bar[2] for bar in bars]
    opens = [bar[0] for bar in bars]
    closes = [bar[3] for bar in bars]

    def pivot_high(index: int) -> bool:
        if index - swing < 0 or index + swing >= total:
            return False
        value = highs[index]
        return all(highs[index + step] < value and highs[index - step] < value
                   for step in range(1, swing + 1))

    def pivot_low(index: int) -> bool:
        if index - swing < 0 or index + swing >= total:
            return False
        value = lows[index]
        return all(lows[index + step] > value and lows[index - step] > value
                   for step in range(1, swing + 1))

    def zone(index: int, direction: int) -> tuple[float, float]:
        base = index
        limit = min(zone_lookback, index)
        for back in range(1, limit + 1):
            candle = index - back
            down = closes[candle] < opens[candle]
            if (direction > 0 and down) or (direction < 0 and not down and closes[candle] > opens[candle]):
                base = candle
                break
        return highs[base], lows[base]

    swing_high = swing_low = None
    high_taken = low_taken = True
    trend = 0
    out: list[tuple[int, int, bool, float, float]] = []

    for bar in range(total):
        confirmed = bar - swing
        if confirmed >= 0:
            if pivot_high(confirmed):
                swing_high, high_taken = highs[confirmed], False
            if pivot_low(confirmed):
                swing_low, low_taken = lows[confirmed], False

        up = closes[bar] if use_close else highs[bar]
        down = closes[bar] if use_close else lows[bar]
        broke_high = swing_high is not None and not high_taken and up > swing_high
        broke_low = swing_low is not None and not low_taken and down < swing_low

        if broke_high:
            choch = trend <= 0
            high_taken, trend = True, 1
            if choch or not shift_only:
                top, bottom = zone(bar, 1)
                out.append((bar, 1, choch, top, bottom))
        if broke_low:
            choch = trend >= 0
            low_taken, trend = True, -1
            if choch or not shift_only:
                top, bottom = zone(bar, -1)
                out.append((bar, -1, choch, top, bottom))
    return out


# ----------------------------------------------- MQL4 style, shift indexing
def mt4_signals(bars: list[Bar], swing: int, shift_only: bool, use_close: bool,
                zone_lookback: int) -> list[tuple[int, int, bool, float, float]]:
    total = len(bars)
    # MetaTrader arrays: index 0 is the newest bar
    high = [bar[1] for bar in reversed(bars)]
    low = [bar[2] for bar in reversed(bars)]
    open_ = [bar[0] for bar in reversed(bars)]
    close = [bar[3] for bar in reversed(bars)]

    def is_pivot_high(shift: int) -> bool:
        if shift - swing < 0 or shift + swing >= total:
            return False
        value = high[shift]
        return all(high[shift + step] < value and high[shift - step] < value
                   for step in range(1, swing + 1))

    def is_pivot_low(shift: int) -> bool:
        if shift - swing < 0 or shift + swing >= total:
            return False
        value = low[shift]
        return all(low[shift + step] > value and low[shift - step] > value
                   for step in range(1, swing + 1))

    def base_candle(shift: int, direction: int) -> int:
        limit = min(zone_lookback, total - shift - 2)
        for back in range(1, limit + 1):
            candle = shift + back
            is_base = close[candle] < open_[candle] if direction > 0 else close[candle] > open_[candle]
            if is_base:
                return candle
        return shift

    start = min(total - swing - 2, total - 1)
    swing_high = swing_low = None
    high_taken = low_taken = True
    trend = 0
    collected: list[tuple[int, int, bool, float, float]] = []

    for shift in range(start, 0, -1):
        candidate = shift + swing
        if is_pivot_high(candidate):
            swing_high, high_taken = high[candidate], False
        if is_pivot_low(candidate):
            swing_low, low_taken = low[candidate], False

        up = close[shift] if use_close else high[shift]
        down = close[shift] if use_close else low[shift]
        broke_high = swing_high is not None and not high_taken and up > swing_high
        broke_low = swing_low is not None and not low_taken and down < swing_low

        if broke_high:
            choch = trend <= 0
            high_taken, trend = True, 1
            if choch or not shift_only:
                candle = base_candle(shift, 1)
                collected.append((total - 1 - shift, 1, choch, high[candle], low[candle]))
        if broke_low:
            choch = trend >= 0
            low_taken, trend = True, -1
            if choch or not shift_only:
                candle = base_candle(shift, -1)
                collected.append((total - 1 - shift, -1, choch, high[candle], low[candle]))

    return collected


# ------------------------------------------------------------------ compare
def main() -> int:
    failures = 0
    checked = 0

    for seed in (1, 2, 3, 7, 11, 21):
        bars = make_bars(1200, seed)
        for swing in (3, 5, 8, 13):
            for shift_only in (False, True):
                for use_close in (True, False):
                    forward = forward_signals(bars, swing, shift_only, use_close, 100)
                    metatrader = mt4_signals(bars, swing, shift_only, use_close, 100)

                    # the MQL4 loop stops at shift 1 and starts swing+2 bars in,
                    # so only the overlapping range is comparable
                    lowest = swing * 2 + 2
                    highest = len(bars) - 2
                    left = [item for item in forward if lowest <= item[0] <= highest]
                    right = [item for item in metatrader if lowest <= item[0] <= highest]
                    checked += 1

                    if left != right:
                        failures += 1
                        print(f"MISMATCH seed={seed} swing={swing} shift_only={shift_only} "
                              f"close={use_close}: forward={len(left)} mt4={len(right)}")
                        for index, (one, two) in enumerate(zip(left, right)):
                            if one != two:
                                print(f"  first difference at {index}: forward={one} mt4={two}")
                                break
                    elif not left:
                        print(f"WARNING no signals for seed={seed} swing={swing} "
                              f"shift_only={shift_only} close={use_close}")

    print(f"{checked} configuration(s) compared, {failures} mismatch(es)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
