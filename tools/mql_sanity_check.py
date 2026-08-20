#!/usr/bin/env python3
"""Static sanity check for the MQL4 and MQL5 sources.

MetaEditor only runs on Windows, so this script catches the mistakes that would
otherwise only show up there:

  * unbalanced braces, parentheses or brackets
  * a called function that is neither defined in the file nor part of the language
  * a constant (clrX, OBJPROP_X, PERIOD_X ...) that is not part of the language
  * declarations that are missing their semicolon

The name lists below only contain what these files are allowed to use, so a typo
such as ``ObjectSetIntger`` or a leak of an MQL5 only property into an MQL4 file
(``OBJPROP_FILL``) is reported instead of silently failing to compile.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MQL_FUNCTIONS = {
    # account
    "AccountBalance", "AccountEquity", "AccountFreeMarginCheck",
    # chart / symbol
    "Bars", "Period", "Symbol", "Digits", "Point", "MarketInfo", "RefreshRates",
    "IndicatorShortName", "Comment", "Print", "Sleep", "GetLastError",
    # series
    "iBars", "iTime", "iOpen", "iHigh", "iLow", "iClose", "iATR", "iBarShift",
    # math
    "MathMin", "MathMax", "MathAbs", "MathFloor", "MathCeil", "MathRound",
    "NormalizeDouble",
    # strings
    "StringFind", "StringSubstr", "StringToInteger", "StringLen", "IntegerToString",
    "DoubleToString", "StringConcatenate",
    # time
    "TimeCurrent", "TimeHour", "TimeMinute", "TimeDayOfYear", "TimeDay", "TimeMonth", "TimeYear",
    # arrays
    "ArrayResize", "ArraySize", "ArrayInitialize",
    # objects
    "ObjectCreate", "ObjectDelete", "ObjectFind", "ObjectMove", "ObjectName", "ObjectsTotal",
    "ObjectSetInteger", "ObjectSetDouble", "ObjectSetString", "ObjectGetInteger",
    # orders
    "OrderSend", "OrderClose", "OrderModify", "OrderSelect", "OrdersTotal", "OrderSymbol",
    "OrderMagicNumber", "OrderType", "OrderTicket", "OrderLots", "OrderOpenPrice",
    "OrderStopLoss", "OrderTakeProfit", "OrderProfit", "OrderComment",
    # terminal state
    "IsTradeAllowed", "IsTesting", "IsOptimization", "IsVisualMode",
    "GlobalVariableSet", "GlobalVariableGet", "GlobalVariableCheck", "GlobalVariableDel",
}

MQL_CONSTANTS = {
    "INIT_SUCCEEDED", "INIT_FAILED", "INIT_PARAMETERS_INCORRECT",
    "OP_BUY", "OP_SELL", "OP_BUYLIMIT", "OP_SELLLIMIT", "OP_BUYSTOP", "OP_SELLSTOP",
    "SELECT_BY_POS", "SELECT_BY_TICKET", "MODE_TRADES", "MODE_HISTORY",
    "MODE_STOPLEVEL", "MODE_FREEZELEVEL", "MODE_TICKVALUE", "MODE_TICKSIZE",
    "MODE_MINLOT", "MODE_MAXLOT", "MODE_LOTSTEP", "MODE_SPREAD", "MODE_DIGITS", "MODE_POINT",
    "PERIOD_M1", "PERIOD_M5", "PERIOD_M15", "PERIOD_M30", "PERIOD_H1", "PERIOD_H4",
    "PERIOD_D1", "PERIOD_W1", "PERIOD_MN1", "PERIOD_CURRENT",
    "OBJ_TEXT", "OBJ_LABEL", "OBJ_ARROW", "OBJ_RECTANGLE", "OBJ_TREND", "OBJ_HLINE",
    "OBJ_VLINE", "OBJ_RECTANGLE_LABEL",
    "OBJPROP_TEXT", "OBJPROP_FONT", "OBJPROP_FONTSIZE", "OBJPROP_COLOR", "OBJPROP_WIDTH",
    # note: OBJPROP_FILL is MQL5 only and must stay out of this list
    "OBJPROP_STYLE", "OBJPROP_BACK", "OBJPROP_SELECTABLE", "OBJPROP_HIDDEN",
    "OBJPROP_CORNER", "OBJPROP_ANCHOR", "OBJPROP_XDISTANCE", "OBJPROP_YDISTANCE",
    "OBJPROP_XSIZE", "OBJPROP_YSIZE", "OBJPROP_BGCOLOR", "OBJPROP_BORDER_TYPE",
    "OBJPROP_ARROWCODE", "OBJPROP_RAY_RIGHT", "OBJPROP_RAY_LEFT",
    "CORNER_LEFT_UPPER", "CORNER_RIGHT_UPPER", "CORNER_LEFT_LOWER", "CORNER_RIGHT_LOWER",
    "ANCHOR_LEFT_UPPER", "ANCHOR_RIGHT_UPPER", "ANCHOR_CENTER", "ANCHOR_UPPER", "ANCHOR_LOWER",
    "BORDER_FLAT", "BORDER_RAISED", "BORDER_SUNKEN",
    "STYLE_SOLID", "STYLE_DASH", "STYLE_DOT", "STYLE_DASHDOT", "STYLE_DASHDOTDOT",
    "Ask", "Bid", "Open", "High", "Low", "Close", "Time", "Volume", "Bars", "Digits", "Point",
    "COLORLITERAL",  # placeholder left by strip_noise for the C'r,g,b' literals
}

TYPES = {
    "void", "int", "double", "bool", "string", "datetime", "color", "long", "ulong", "short",
    "char", "uchar", "uint", "float", "enum", "struct", "const", "input", "extern", "static",
    "return", "if", "else", "for", "while", "switch", "case", "default", "break", "continue",
    "true", "false", "NULL", "new", "delete", "sizeof", "group", "sinput",
}

# ---------------------------------------------------------------- MQL5 additions
MQL5_FUNCTIONS = {
    "CopyRates", "CopyTime", "CopyHigh", "CopyLow", "CopyClose", "CopyOpen", "CopyBuffer",
    "ArraySetAsSeries", "ArrayResize", "ArraySize", "ArrayInitialize",
    "iATR", "iMA", "IndicatorRelease",
    "SymbolInfoDouble", "SymbolInfoInteger", "SymbolInfoString", "SymbolInfoTick",
    "AccountInfoDouble", "AccountInfoInteger", "OrderCalcMargin",
    "PositionsTotal", "PositionGetTicket", "PositionSelectByTicket", "PositionGetInteger",
    "PositionGetDouble", "PositionGetString",
    "TerminalInfoInteger", "MQLInfoInteger", "PeriodSeconds", "ChartRedraw",
    "TimeToStruct", "TimeCurrent", "StringFormat", "PrintFormat", "Print",
    "NormalizeDouble", "MathAbs", "MathMin", "MathMax", "MathFloor", "MathCeil", "MathRound",
    "StringFind", "StringSubstr", "StringToInteger", "IntegerToString", "DoubleToString",
    "ObjectCreate", "ObjectDelete", "ObjectFind", "ObjectMove", "ObjectName", "ObjectsTotal",
    "ObjectSetInteger", "ObjectSetDouble", "ObjectSetString",
    "GlobalVariableSet", "GlobalVariableGet", "GlobalVariableCheck",
}

MQL5_CONSTANTS = {
    "PERIOD_CURRENT", "PERIOD_M1", "PERIOD_M2", "PERIOD_M3", "PERIOD_M4", "PERIOD_M5",
    "PERIOD_M6", "PERIOD_M10", "PERIOD_M12", "PERIOD_M15", "PERIOD_M20", "PERIOD_M30",
    "PERIOD_H1", "PERIOD_H2", "PERIOD_H3", "PERIOD_H4", "PERIOD_H6", "PERIOD_H8",
    "PERIOD_H12", "PERIOD_D1", "PERIOD_W1", "PERIOD_MN1",
    "SYMBOL_POINT", "SYMBOL_DIGITS", "SYMBOL_TRADE_STOPS_LEVEL", "SYMBOL_TRADE_FREEZE_LEVEL",
    "SYMBOL_TRADE_TICK_VALUE", "SYMBOL_TRADE_TICK_VALUE_LOSS", "SYMBOL_TRADE_TICK_SIZE",
    "SYMBOL_VOLUME_MIN", "SYMBOL_VOLUME_MAX", "SYMBOL_VOLUME_STEP",
    "ACCOUNT_BALANCE", "ACCOUNT_EQUITY", "ACCOUNT_MARGIN_FREE",
    "POSITION_SYMBOL", "POSITION_MAGIC", "POSITION_TYPE", "POSITION_VOLUME",
    "POSITION_PRICE_OPEN", "POSITION_SL", "POSITION_TP",
    "POSITION_TYPE_BUY", "POSITION_TYPE_SELL", "ORDER_TYPE_BUY", "ORDER_TYPE_SELL",
    "TERMINAL_TRADE_ALLOWED", "MQL_TRADE_ALLOWED", "MQL_TESTER",
    "INVALID_HANDLE", "MODE_EMA", "MODE_SMA", "PRICE_CLOSE",
    "MqlRates", "MqlTick", "MqlDateTime", "ENUM_TIMEFRAMES", "CTrade",
    "OBJPROP_FILL",  # MQL5 only, rectangles need it to be filled
    "_Symbol", "_Point", "_Digits", "_Period",
}

# methods of the standard library objects used through an instance (trade.Buy(...))
MQL5_METHODS = {
    "Buy", "Sell", "PositionModify", "PositionClose", "PositionClosePartial",
    "SetExpertMagicNumber", "SetDeviationInPoints", "SetTypeFillingBySymbol", "SetMarginMode",
    "ResultRetcode", "ResultRetcodeDescription", "ResultOrder", "ResultDeal", "ResultPrice",
}

IDENTIFIER = re.compile(r"(?<![.\w])([A-Za-z_][A-Za-z0-9_]*)\b")
CALL = re.compile(r"(?<![.\w])([A-Za-z_][A-Za-z0-9_]*)\s*\(")
MEMBER_CALL = re.compile(r"\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(")
DEFINITION = re.compile(
    r"^\s*(?:void|int|double|bool|string|datetime|color|long|ulong|ENUM_TIMEFRAMES)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)\s*\(",
    re.MULTILINE,
)


def strip_noise(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"^\s*#[^\n]*", "", text, flags=re.MULTILINE)  # #property, #define
    text = re.sub(r"C'\s*\d+\s*,\s*\d+\s*,\s*\d+\s*'", "COLORLITERAL", text)
    text = re.sub(r'"(?:[^"\\]|\\.)*"', '""', text)
    text = re.sub(r"'(?:[^'\\]|\\.)*'", "''", text)
    return text


def check_balance(name: str, text: str) -> list[str]:
    problems: list[str] = []
    pairs = {")": "(", "}": "{", "]": "["}
    stack: list[tuple[str, int]] = []
    line = 1
    for char in text:
        if char == "\n":
            line += 1
        elif char in "({[":
            stack.append((char, line))
        elif char in ")}]":
            if not stack or stack[-1][0] != pairs[char]:
                problems.append(f"{name}:{line}: unexpected '{char}'")
                return problems
            stack.pop()
    for char, opened in stack:
        problems.append(f"{name}:{opened}: '{char}' is never closed")
    return problems


def check_names(name: str, text: str, mql5: bool) -> list[str]:
    problems: list[str] = []
    functions = MQL_FUNCTIONS | MQL5_FUNCTIONS if mql5 else MQL_FUNCTIONS
    constants = MQL_CONSTANTS | MQL5_CONSTANTS if mql5 else MQL_CONSTANTS
    methods = MQL5_METHODS if mql5 else set()

    defined = set(DEFINITION.findall(text))
    declared: set[str] = set()

    # inputs, globals, locals, enum members and parameters, including the
    # comma separated and the "by reference array" forms
    for pattern in (
        r"\b(?:input|extern|static)?\s*(?:int|double|bool|string|datetime|color|long)\s+&?\s*([A-Za-z_]\w*)",
        r"\benum\s+([A-Za-z_]\w*)",
        r"\b([A-Za-z_]\w*)\s*=\s*\d+\s*[,}]",                       # enum members
        r"\b(?:input|extern)\s+[A-Za-z_]\w*\s+([A-Za-z_]\w*)",      # enum typed inputs
        r"&\s*([A-Za-z_]\w*)\s*\[",                                  # array by reference
        r",\s*([A-Za-z_]\w*)\s*(?:=|,|;|\[)",                        # extra declarators
        r"\b(?:int|double|bool|string|datetime|color)\s+([A-Za-z_]\w*)\s*\[",
        r"\b(?:MqlRates|MqlTick|MqlDateTime|CTrade)\s+&?\s*([A-Za-z_]\w*)",  # struct instances
    ):
        declared.update(re.findall(pattern, text))

    known_calls = functions | defined | TYPES
    for called in sorted(set(CALL.findall(text))):
        if called not in known_calls:
            problems.append(f"{name}: call to unknown function '{called}'")

    for called in sorted(set(MEMBER_CALL.findall(text))):
        if called not in methods:
            problems.append(f"{name}: call to unknown method '{called}'")

    known_names = known_calls | constants | declared
    for used in sorted(set(IDENTIFIER.findall(text))):
        if used in known_names:
            continue
        if used.startswith("clr") or used.startswith("GTE_") or used.startswith("g_"):
            continue
        if used.isupper() or used.startswith("COLORLITERAL"):
            problems.append(f"{name}: unknown constant '{used}'")
        else:
            problems.append(f"{name}: unknown identifier '{used}'")
    return problems


def check_semicolons(name: str, lines: list[str], mql5: bool) -> list[str]:
    problems: list[str] = []
    for number, raw in enumerate(lines, start=1):
        line = re.sub(r"//.*$", "", raw).strip()
        if not line or line.startswith("#") or line.startswith("/*") or line.startswith("*"):
            continue
        if mql5 and line.startswith("input group"):
            continue  # documented MQL5 syntax, no semicolon
        if line.startswith(("input ", "extern ")) and not line.endswith((";", "{", "}")):
            problems.append(f"{name}:{number}: declaration without a semicolon")
    return problems


def main() -> int:
    targets = (
        sorted(Path(".").glob("**/*.mq4"))
        + sorted(Path(".").glob("**/*.mq5"))
        + sorted(Path(".").glob("**/*.mqh"))
    )
    if not targets:
        print("no MetaTrader files found")
        return 1

    failed = False
    for target in targets:
        raw = target.read_text(encoding="utf-8")
        clean = strip_noise(raw)
        mql5 = target.suffix == ".mq5"
        problems = check_balance(target.name, clean)
        problems += check_names(target.name, clean, mql5)
        problems += check_semicolons(target.name, raw.splitlines(), mql5)
        if problems:
            failed = True
            for problem in problems:
                print(problem)
        else:
            print(f"{target}: ok")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
