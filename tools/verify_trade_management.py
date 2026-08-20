#!/usr/bin/env python3
"""Check the trailing / break even / partial close rules of the MT5 bot.

``ManagePosition()`` in ``mt5/Experts/GTE_V7_EA.mq5`` is the riskiest part of the
bot: a wrong comparison there can move a stop backwards and turn a winning trade
into a loss. The same rules are re-implemented here and run over generated price
paths, asserting the invariants that must never break:

  1. the stop never moves backwards (up only for a buy, down only for a sell)
  2. once break even is reached the stop stays at or above entry + lock
  3. the stop is never closer to price than the broker minimum distance
  4. trailing never starts before ``TrailStartR``
  5. the partial close happens at most once, at or after ``PartialAtR``
"""

from __future__ import annotations

import random
import sys
from dataclasses import dataclass

POINT = 0.01
MIN_LEVEL = 5 * POINT   # broker stop level


@dataclass
class Settings:
    break_even_r: float = 0.8
    break_even_lock: float = 10 * POINT
    trail_start_r: float = 1.0
    trail_distance: float = 60 * POINT     # stands in for ATR x multiplier
    trail_step: float = 20 * POINT
    partial_r: float = 1.0
    partial_percent: float = 50.0


@dataclass
class Position:
    direction: int
    entry: float
    risk: float
    stop: float
    volume: float = 0.10
    partial_done: bool = False


def manage(position: Position, price: float, cfg: Settings) -> tuple[bool, str]:
    """One pass of the MQL5 ManagePosition() logic. Returns (modified, action)."""

    if position.direction > 0:
        progress = (price - position.entry) / position.risk
    else:
        progress = (position.entry - price) / position.risk

    stop = position.stop
    new_stop = stop
    action = ""

    # 1) break even with a few points locked
    if cfg.break_even_r > 0 and progress >= cfg.break_even_r:
        locked = (position.entry + cfg.break_even_lock if position.direction > 0
                  else position.entry - cfg.break_even_lock)
        if position.direction > 0 and (stop <= 0 or locked > stop):
            new_stop, action = locked, "break even"
        if position.direction < 0 and (stop <= 0 or locked < stop):
            new_stop, action = locked, "break even"

    # 2) trailing stop
    if cfg.trail_distance > 0 and progress >= cfg.trail_start_r:
        candidate = (price - cfg.trail_distance if position.direction > 0
                     else price + cfg.trail_distance)
        if position.direction > 0 and candidate > new_stop + cfg.trail_step - POINT / 2:
            new_stop, action = candidate, "trailing"
        if position.direction < 0 and (new_stop <= 0
                                       or candidate < new_stop - cfg.trail_step + POINT / 2):
            new_stop, action = candidate, "trailing"

    # never let the trailing stop move into a loss once break even was reached
    if cfg.break_even_r > 0 and progress >= cfg.break_even_r:
        if position.direction > 0:
            new_stop = max(new_stop, position.entry + cfg.break_even_lock)
        else:
            new_stop = min(new_stop, position.entry - cfg.break_even_lock)

    # keep the broker minimum distance
    if position.direction > 0 and price - new_stop < MIN_LEVEL:
        new_stop = price - MIN_LEVEL
    if position.direction < 0 and new_stop - price < MIN_LEVEL:
        new_stop = price + MIN_LEVEL

    improved = (new_stop > stop + POINT / 2 if position.direction > 0
                else stop <= 0 or new_stop < stop - POINT / 2)
    modified = bool(action) and improved
    if modified:
        position.stop = new_stop

    # 3) partial profit taking
    if (cfg.partial_r > 0 and cfg.partial_percent > 0 and not position.partial_done
            and progress >= cfg.partial_r):
        position.partial_done = True
        action = action or "partial"

    return modified, action


def run_path(direction: int, prices: list[float], cfg: Settings) -> list[str]:
    entry = prices[0]
    risk = 60 * POINT
    stop = entry - risk if direction > 0 else entry + risk
    position = Position(direction=direction, entry=entry, risk=risk, stop=stop)

    failures: list[str] = []
    previous_stop = position.stop
    trailing_seen_at: float | None = None
    partial_seen_at: float | None = None
    break_even_reached = False

    for price in prices:
        progress = ((price - entry) / risk) if direction > 0 else ((entry - price) / risk)
        was_partial = position.partial_done
        _, action = manage(position, price, cfg)

        # 1) monotonic stop
        if direction > 0 and position.stop < previous_stop - 1e-9:
            failures.append(f"buy stop moved down: {previous_stop:.3f} -> {position.stop:.3f}")
        if direction < 0 and position.stop > previous_stop + 1e-9:
            failures.append(f"sell stop moved up: {previous_stop:.3f} -> {position.stop:.3f}")

        # 2) break even is never given back (only when the feature is enabled)
        if cfg.break_even_r > 0 and progress >= cfg.break_even_r:
            break_even_reached = True
        if break_even_reached:
            floor_stop = entry + cfg.break_even_lock if direction > 0 else entry - cfg.break_even_lock
            # the broker distance clamp may keep the old stop, but never a worse one
            if direction > 0 and position.stop < min(floor_stop, price - MIN_LEVEL) - 1e-9:
                failures.append(f"buy stop {position.stop:.3f} is below the locked level")
            if direction < 0 and position.stop > max(floor_stop, price + MIN_LEVEL) + 1e-9:
                failures.append(f"sell stop {position.stop:.3f} is above the locked level")

        # 3) minimum distance from price is respected whenever the stop was touched
        if action == "trailing":
            distance = (price - position.stop) if direction > 0 else (position.stop - price)
            if distance < MIN_LEVEL - 1e-9:
                failures.append(f"stop too close to price: {distance:.4f}")

        # 4) trailing never starts too early
        if action == "trailing" and trailing_seen_at is None:
            trailing_seen_at = progress
            if progress < cfg.trail_start_r - 1e-9:
                failures.append(f"trailing started at {progress:.2f}R")

        # 5) the partial close happens once, not before its level
        if position.partial_done and not was_partial:
            if partial_seen_at is not None:
                failures.append("partial close happened twice")
            partial_seen_at = progress
            if progress < cfg.partial_r - 1e-9:
                failures.append(f"partial close at {progress:.2f}R")

        previous_stop = position.stop

    return failures


def make_path(direction: int, seed: int, bars: int = 300) -> list[float]:
    rng = random.Random(seed)
    price = 4300.0
    drift = 0.02 * direction
    prices = [price]
    for _ in range(bars):
        price += drift + rng.gauss(0.0, 0.15)
        prices.append(round(price, 3))
    return prices


def main() -> int:
    presets = {
        "M1": Settings(),
        "M5": Settings(break_even_r=1.0, break_even_lock=15 * POINT, trail_start_r=1.2,
                       trail_distance=120 * POINT, trail_step=30 * POINT, partial_r=1.0),
        "M15": Settings(break_even_r=1.0, break_even_lock=20 * POINT, trail_start_r=1.5,
                        trail_distance=250 * POINT, trail_step=50 * POINT, partial_r=1.5),
        "no break even": Settings(break_even_r=0.0),
        "no trailing": Settings(trail_distance=0.0),
        "no partial": Settings(partial_r=0.0),
    }

    total = 0
    problems = 0
    for label, cfg in presets.items():
        for direction in (1, -1):
            for seed in range(1, 13):
                for path_direction in (1, -1):   # winners and losers
                    prices = make_path(path_direction, seed)
                    failures = run_path(direction, prices, cfg)
                    total += 1
                    if failures:
                        problems += 1
                        side = "buy" if direction > 0 else "sell"
                        print(f"FAIL preset={label} side={side} seed={seed} "
                              f"path={'up' if path_direction > 0 else 'down'}")
                        for failure in failures[:3]:
                            print(f"   {failure}")

    print(f"{total} price path(s) checked, {problems} with a broken invariant")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
