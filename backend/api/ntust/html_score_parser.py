"""
NTUST 成績查詢系統 HTML → JSON 解析器

用途：
    將 NTUST 學務系統 (StuScoreQueryServ) 的成績查詢頁面 HTML 轉為結構化 JSON。

使用方式：
    # 以 CLI 使用
    python ntust_score_parser.py input.html -o output.json
    python ntust_score_parser.py input.html           # 直接印到 stdout
    cat input.html | python ntust_score_parser.py -   # 從 stdin 讀取

    # 以模組 import
    from ntust_score_parser import parse
    data = parse(html_string)

依賴：
    pip install beautifulsoup4 lxml
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from bs4 import BeautifulSoup, Tag


# ---------------------------------------------------------------------------
# 共用常數
# ---------------------------------------------------------------------------

# 學分欄的特殊標記 → credit_type
# 比對順序會影響結果，請勿隨意調整
_CREDIT_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"^\[\s*(\d+)\s*]$"),  "education_program"),  # [3]
    (re.compile(r"^<\s*(\d+)\s*>$"),   "not_counted"),        # <3>
    (re.compile(r"^#\s*(\d+)\s*$"),    "not_required"),       # #3
    (re.compile(r"^\(\s*(\d+)\s*\)$"), "not_earned"),         # (3) - 不及格
    (re.compile(r"^(\d+)$"),           "normal"),             # 3
]


# ---------------------------------------------------------------------------
# 輔助函式
# ---------------------------------------------------------------------------

def _text(node: Tag | None) -> str:
    """取得節點純文字並壓縮空白，None 回傳空字串。"""
    if node is None:
        return ""
    return " ".join(node.get_text(strip=True).split())


def _to_int(value: str) -> int | None:
    try:
        return int(value.strip())
    except (ValueError, AttributeError):
        return None


def _to_float(value: str) -> float | None:
    try:
        return float(value.strip())
    except (ValueError, AttributeError):
        return None


def _parse_credits(raw: str) -> tuple[int | None, str]:
    """
    解析學分欄位字串，回傳 (學分數, 類型)。

    >>> _parse_credits("3")     # ('normal', 3)
    >>> _parse_credits("[3]")   # ('education_program', 3)
    >>> _parse_credits("<3>")   # ('not_counted', 3)
    >>> _parse_credits("#3")    # ('not_required', 3)
    >>> _parse_credits("(4)")   # ('not_earned', 4)
    """
    text = raw.strip()
    for pattern, credit_type in _CREDIT_PATTERNS:
        m = pattern.match(text)
        if m:
            return int(m.group(1)), credit_type
    return None, "unknown"


def _classify_status(grade: str, remark: str) -> str:
    """
    根據成績欄 + 備註欄推斷狀態。

    回傳值：
        graded   - 已有等第成績（A+, A, ..., D, E, F）
        pending  - 成績未到
        passed   - 通過（Pass/Fail 課程）
        withdrew - 二次退選
        exempted - 抵免
        unknown  - 無法判斷
    """
    g, r = grade.strip(), remark.strip()

    if "二次退選" in g or "二次退選" in r:
        return "withdrew"
    if "抵免" in r:
        return "exempted"
    if "成績未到" in g:
        return "pending"
    if g == "通過" or g == "不通過":
        return "passed"
    if g == "":
        return "unknown"
    # 其餘皆視為等第制已評定（含 D, E, F 等不及格狀況）
    return "graded"


def _find_box_by_title(soup: BeautifulSoup, title: str) -> Tag | None:
    """
    依 box-header 裡的標題文字定位對應的 div.box 區塊。
    比位置依賴更健壯，對版面微調有抗性。
    """
    for box in soup.select("div.box"):
        header = box.select_one(".box-header h2")
        if header and title in _text(header):
            return box
    return None


def _rows_of(table: Tag) -> list[list[Tag]]:
    """
    將 table 拆成 2D cell list，自動跳過完全空白的列。
    用 find_all('tr') 而非 children，以兼顧 HTML 缺漏 </tr> 的情境。
    """
    rows: list[list[Tag]] = []
    for tr in table.find_all("tr"):
        cells = tr.find_all(["td", "th"])
        if cells:
            rows.append(cells)
    return rows


# ---------------------------------------------------------------------------
# 各區塊解析函式
# ---------------------------------------------------------------------------

def _parse_student(soup: BeautifulSoup) -> str:
    """從 navbar 抽出學生姓名。"""
    # navbar-right 的第一個 nav-link 就是姓名
    for a in soup.select("ul.navbar-right a.nav-link"):
        name = _text(a)
        # 排除「登出」、「English」等其他連結
        if name and name not in {"登出", "Logout", "English"}:
            return name
    return ""


def _parse_current_term(soup: BeautifulSoup) -> str:
    """
    從 alert-info 抽取「期末評量時間」對應的學年期代碼。
    範例文字："期末評量時間 1142 2026/05/22-2026/06/05"
    """
    for alert in soup.select("div.alert-info"):
        text = _text(alert)
        m = re.search(r"期末評量時間\s*(\d{4})", text)
        if m:
            return m.group(1)
    return ""


def _parse_rankings(soup: BeautifulSoup) -> list[dict[str, Any]]:
    """解析「排名資料」表格。"""
    box = _find_box_by_title(soup, "排名資料")
    if box is None:
        return []

    table = box.select_one("table")
    if table is None:
        return []

    rankings: list[dict[str, Any]] = []
    rows = _rows_of(table)

    # 第一列是表頭，跳過
    for cells in rows[1:]:
        if len(cells) < 7:
            continue
        rankings.append({
            "term": _text(cells[0]),
            "semester": {
                "class_rank": _to_int(_text(cells[1])),
                "dept_rank":  _to_int(_text(cells[2])),
                "gpa":        _to_float(_text(cells[3])),
            },
            "cumulative": {
                "class_rank": _to_int(_text(cells[4])),
                "dept_rank":  _to_int(_text(cells[5])),
                "gpa":        _to_float(_text(cells[6])),
            },
        })

    return rankings


def _parse_courses(soup: BeautifulSoup) -> list[dict[str, Any]]:
    """解析「歷年學業成績列表」表格。"""
    box = _find_box_by_title(soup, "歷年學業成績列表")
    if box is None:
        return []

    # box 內可能有兩張 table（成績 + 統計），取第一張
    table = box.select_one("table")
    if table is None:
        return []

    courses: list[dict[str, Any]] = []
    rows = _rows_of(table)

    for cells in rows[1:]:  # 跳過表頭
        if len(cells) < 9:
            continue

        credits_raw = _text(cells[4])
        credits, credit_type = _parse_credits(credits_raw)

        grade = _text(cells[5])
        remark = _text(cells[6])
        status = _classify_status(grade, remark)

        ge_dim = _text(cells[7]) or None
        distance_raw = _text(cells[8])
        distance_learning = bool(distance_raw) and distance_raw not in {"否", "N"}

        courses.append({
            "index":             _to_int(_text(cells[0])),
            "term":              _text(cells[1]),
            "code":              _text(cells[2]),
            "name":              _text(cells[3]),
            "credits":           credits,
            "credit_type":       credit_type,
            "grade":             grade,
            "status":            status,
            "remark":            remark,
            "ge_dimension":      ge_dim,
            "distance_learning": distance_learning,
        })

    return courses


def _parse_credit_summary(soup: BeautifulSoup) -> dict[str, Any]:
    """解析最下方的學分統計表（位於 DataTables_Table_0_info 內）。"""
    info = soup.select_one("#DataTables_Table_0_info table")
    if info is None:
        return {}

    rows = _rows_of(info)
    # 預期結構：
    #   rows[0] = ['類別', '實體課程', '遠距教學課程', '合計']
    #   rows[1] = ['已實得學分數', <display>68</display>, ...]
    #   rows[2] = ['修習中學分數', ...]
    #   rows[3] = ['合計', ...]
    #   rows[4] = ['備註...']  ← 忽略

    label_to_key = {
        "已實得學分數": "earned",
        "修習中學分數": "enrolled",
        "合計":         "total",
    }

    summary: dict[str, Any] = {}
    for cells in rows[1:]:
        if len(cells) < 4:
            continue
        label = _text(cells[0])
        key = label_to_key.get(label)
        if key is None:
            continue
        summary[key] = {
            "in_person": _to_int(_text(cells[1])) or 0,
            "distance":  _to_int(_text(cells[2])) or 0,
            "total":     _to_int(_text(cells[3])) or 0,
        }

    return summary


# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------

def parse(html: str) -> dict[str, Any]:
    """將 NTUST 成績查詢 HTML 解析為結構化 dict。"""
    soup = BeautifulSoup(html, "lxml")
    return {
        "student":        _parse_student(soup),
        "current_term":   _parse_current_term(soup),
        "rankings":       _parse_rankings(soup),
        "courses":        _parse_courses(soup),
        "credit_summary": _parse_credit_summary(soup),
    }


def _read_input(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    return Path(path).read_text(encoding="utf-8")


def _cli() -> None:
    ap = argparse.ArgumentParser(
        description="將 NTUST 成績查詢 HTML 轉為 JSON",
    )
    ap.add_argument(
        "input",
        help="輸入 HTML 檔路徑，使用 '-' 從 stdin 讀取",
    )
    ap.add_argument(
        "-o", "--output",
        help="輸出 JSON 檔路徑（省略則輸出到 stdout）",
    )
    ap.add_argument(
        "--indent",
        type=int, default=2,
        help="JSON 縮排，設 0 表示單行壓縮（預設 2）",
    )
    args = ap.parse_args()

    html = _read_input(args.input)
    data = parse(html)

    indent = args.indent if args.indent > 0 else None
    out = json.dumps(data, ensure_ascii=False, indent=indent)

    if args.output:
        Path(args.output).write_text(out + "\n", encoding="utf-8")
        print(f"✔ 已輸出至 {args.output}", file=sys.stderr)
    else:
        print(out)


if __name__ == "__main__":
    _cli()
