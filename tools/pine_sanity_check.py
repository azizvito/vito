#!/usr/bin/env python3
"""Lightweight sanity checker for the Pine Script sources in this repository.

It cannot replace the TradingView compiler, it only catches the mistakes that are
easy to make by hand and impossible to see by eye:

  * unbalanced ( ) [ ] inside a logical statement
  * a block indentation that is not a multiple of 4 spaces
  * a continuation line indented by a multiple of 4 (TradingView reads that as a
    new statement instead of the continuation of the previous one)
  * tabs mixed with spaces
"""

from __future__ import annotations

import sys
from pathlib import Path


def strip_comment(line: str) -> str:
    out, in_str = [], None
    i = 0
    while i < len(line):
        ch = line[i]
        if in_str:
            if ch == in_str:
                in_str = None
            out.append(ch)
        elif ch in "'\"":
            in_str = ch
            out.append(ch)
        elif ch == "/" and line[i + 1: i + 2] == "/":
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def check(path: Path) -> list[str]:
    problems: list[str] = []
    lines = path.read_text(encoding="utf-8").splitlines()

    depth = 0
    stmt_start_line = 0
    stmt_indent = 0

    for no, raw in enumerate(lines, start=1):
        if "\t" in raw:
            problems.append(f"{path.name}:{no}: tab character, Pine wants spaces")

        code = strip_comment(raw)
        if not code.strip():
            continue

        indent = len(code) - len(code.lstrip(" "))

        if depth == 0:
            if indent % 4 != 0:
                problems.append(
                    f"{path.name}:{no}: statement indented {indent} spaces, expected a multiple of 4"
                )
            stmt_start_line = no
            stmt_indent = indent
        else:
            # continuation of a statement that is still open
            delta = indent - stmt_indent
            if delta <= 0 or delta % 4 == 0:
                problems.append(
                    f"{path.name}:{no}: continuation of line {stmt_start_line} is indented "
                    f"{indent} spaces (delta {delta}); Pine needs a non multiple of 4 deeper indent"
                )

        opened = depth
        in_str = None
        for ch in code:
            if in_str:
                if ch == in_str:
                    in_str = None
                continue
            if ch in "'\"":
                in_str = ch
            elif ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
                if depth < 0:
                    problems.append(f"{path.name}:{no}: closing bracket without an opening one")
                    depth = 0
        if opened == 0 and depth == 0:
            stmt_start_line = no

    if depth != 0:
        problems.append(f"{path.name}: {depth} bracket(s) never closed")

    return problems


def main() -> int:
    targets = sorted(Path(".").glob("**/*.pine"))
    if not targets:
        print("no .pine files found")
        return 1

    failed = False
    for target in targets:
        problems = check(target)
        if problems:
            failed = True
            for problem in problems:
                print(problem)
        else:
            print(f"{target}: ok")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
