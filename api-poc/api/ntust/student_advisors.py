"""Each semester's advisor (導師), from the student records system (學籍管理系統).

The portal page (`subsystem.py`) answers without a session and links 學籍管理系統 at
`stuinfosys.ntust.edu.tw/StudentInformation`, which signs in through ssoam2's OIDC and gets the
code back by a form_post page that `NtustSsoBridge` submits. The sign-in ends on `Home/Index`,
whose menu links 學籍資料檢視 (`Information/Index`, UTF-8); opening the system's root again runs
the OIDC round once more, signed in or not. 學籍資料檢視 shows the student's record in named form
inputs and, at its bottom, each semester's advisor.

That advisor block is no `<table>`: the page has none. `parse_advisors` reads a th-headed table,
so on the real page it finds nothing, and the probe prints the page's skeleton (selectors and the
kind and length of each leaf's text, never the text) and its scripts' paths, from which the
block's parser is to be written.

The page is the student's own record: the probe prints only the advisor table, each name cut to
its first character unless `--show` is passed. Stderr holds the request trace (method, host,
path, status), the page's title, ssoam2's refusal and shapes, and no other page text. Cookies
stay in memory.
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import sys
from collections.abc import Callable
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup, Comment, Tag

from api import load_creds
from api.ntust.sso import NtustSsoBridge
from api.ntust.subsystem import SUBSYSTEM_URL_ZH, parse_subsystems

RECORDS_SYSTEM = "學籍管理系統"
RECORDS_VIEW = "學籍資料檢視"
ADVISOR = "導師"
SEMESTER_LABELS = ("學年", "學期")
# What a semester cell may hold to be printed as is; anything else is masked like a name.
SEMESTER_SHAPE = re.compile(r"[0-9\s/學年度第期上下暑H-]+")
SSO_HOST = "ssoam2.ntust.edu.tw"
# Where ssoam2 writes why it refused a sign-in, as HTMLParser.loginErrorMessage reads it.
SSO_ERROR_CLASSES = ("field-validation-error", "validation-summary-errors", "alert-danger", "text-danger")
# A path segment this long is a token, not a page name.
TOKEN_LENGTH = 32
HAN = range(0x4E00, 0xA000)
SKELETON_DEPTH = 16
UNSHOWN_TAGS = frozenset({"head", "script", "style", "svg", "noscript"})
# A quoted path or address in a script, cut before any query.
URL_LITERAL = re.compile(r"""["'`](/[\w/.-]+|https?://[^"'`\s?]+)""")


def mask(name: str) -> str:
    """王小明 -> 王○○."""
    return name[:1] + "○" * (len(name) - 1)


def _text(node: Tag) -> str:
    return " ".join(node.get_text(" ", strip=True).split())


def _rows(table: Tag) -> list[list[Tag]]:
    """The table's own rows as cell lists, without the rows of tables nested in it."""
    return [
        tr.find_all(["th", "td"], recursive=False)
        for tr in table.find_all("tr")
        if tr.find_parent("table") is table
    ]


def parse_advisors(html: str) -> dict[str, object] | None:
    """Headers and semester/advisor rows of the last table whose `<th>` row names 導師.

    None when the page has no such table (a sign-in page, a redesign), which is not the same as
    a table with no rows. Only an all-`<th>` row counts as headers, so a `<th>導師</th><td>`
    pair elsewhere on the page is never read as one.
    """
    soup = BeautifulSoup(html, "html.parser")
    for table in reversed(soup.find_all("table")):
        rows = _rows(table)
        for at, cells in enumerate(rows):
            if not cells or any(cell.name != "th" for cell in cells):
                continue
            headers = [_text(cell) for cell in cells]
            advisor = next((i for i, h in enumerate(headers) if ADVISOR in h), None)
            if advisor is None:
                continue
            semester = [
                i for i, h in enumerate(headers)
                if i != advisor and any(label in h for label in SEMESTER_LABELS)
            ]
            semesters = []
            for row in rows[at + 1:]:
                if len(row) != len(headers):
                    continue
                texts = [_text(cell) for cell in row]
                semesters.append({
                    "semester": " ".join(texts[i] for i in semester if texts[i]),
                    "advisor": texts[advisor],
                })
            return {"headers": headers, "rows": semesters}
    return None


def shown(result: dict[str, object], show: bool) -> dict[str, object]:
    """The parsed table as printed: names masked unless `show`."""
    rows = [
        {
            "semester": row["semester"]
            if show or SEMESTER_SHAPE.fullmatch(row["semester"]) else mask(row["semester"]),
            "advisor": row["advisor"] if show else mask(row["advisor"]),
        }
        for row in result["rows"]
    ]
    return {"headers": result["headers"], "row_count": len(rows), "rows": rows}


def _link(resp: httpx.Response, name: str) -> str | None:
    soup = BeautifulSoup(resp.text, "html.parser")
    for a in soup.find_all("a", href=True):
        href = a["href"].strip()
        if name in _text(a) and href and not href.startswith(("#", "javascript:")):
            return urljoin(str(resp.url), href)
    return None


# ---------------- stderr: no page text ----------------

def _redact(text: str, student_id: str) -> str:
    return re.sub(re.escape(student_id), "<id>", text, flags=re.IGNORECASE)


def _path(url: httpx.URL, student_id: str) -> str:
    """The URL's path, never its query, with the student ID and token-length segments blanked."""
    segments = _redact(url.path, student_id).split("/")
    return "/".join("<token>" if len(s) >= TOKEN_LENGTH else s for s in segments)


def _trace(student_id: str, last: list[httpx.Response]) -> Callable[[httpx.Response], None]:
    """Prints each hop and keeps the latest in `last`, as the bridge hands back no page."""
    def hook(resp: httpx.Response) -> None:
        last[:] = [resp]
        print(
            f"  {resp.request.method} {resp.url.host}{_path(resp.url, student_id)}"
            f" {resp.status_code}",
            file=sys.stderr,
        )
    return hook


def _kind(text: str) -> str:
    """Text as its kind and length: c Han, d digits, x other, e empty; `*` marks 導師."""
    if not text:
        return "e"
    if text.isdigit():
        kind = "d"
    elif all(ord(ch) in HAN for ch in text):
        kind = "c"
    else:
        kind = "x"
    return f"{kind}{len(text)}" + ("*" if ADVISOR in text else "")


def _selector(tag: Tag) -> str:
    return (
        tag.name
        + (f"#{tag['id']}" if tag.get("id") else "")
        + "".join(f".{c}" for c in tag.get("class", []))
        + (f"@{tag['name']}" if tag.name == "input" and tag.get("name") else "")
        + "".join(f"/{a[0]}{tag[a]}" for a in ("rowspan", "colspan") if tag.get(a))
    )


def _skeleton(el: Tag, depth: int = SKELETON_DEPTH) -> str:
    """The element tree as selectors and text kinds, never the text; equal neighbours fold."""
    if el.name == "input":
        own = el.get("value", "")
    else:
        own = " ".join(
            s.strip() for s in el.find_all(string=True, recursive=False)
            if not isinstance(s, Comment) and s.strip()
        )
    kids = [kid for kid in el.find_all(True, recursive=False) if kid.name not in UNSHOWN_TAGS]
    shape = _selector(el) + (f":{_kind(own)}" if own or not kids else "")
    if not kids:
        return shape
    if depth == 0:
        return shape + "[...]"
    runs: list[list] = []
    for kid in kids:
        inner = _skeleton(kid, depth - 1)
        if runs and runs[-1][0] == inner:
            runs[-1][1] += 1
        else:
            runs.append([inner, 1])
    return shape + "[" + " ".join(s if n == 1 else f"{s}x{n}" for s, n in runs) + "]"


def _scripts(soup: BeautifulSoup) -> tuple[list[str], list[str], bool]:
    """Script sources and the addresses inline scripts quote, as paths, and whether they name 導師."""
    sources = [s["src"].split("?")[0] for s in soup.find_all("script", src=True)]
    inline = "\n".join(s.get_text() for s in soup.find_all("script") if not s.get("src"))
    return sources, sorted(set(URL_LITERAL.findall(inline))), ADVISOR in inline


def _describe(resp: httpx.Response, student_id: str, structure: bool) -> None:
    soup = BeautifulSoup(resp.text, "html.parser")
    meta = soup.find("meta", charset=True)
    title = _text(soup.title) if soup.title else ""
    inputs = sorted({i["name"] for i in soup.find_all("input", attrs={"name": True})})
    lines = [
        f"  page {resp.url.host}{_path(resp.url, student_id)} {resp.status_code},"
        f" content-type {resp.headers.get('content-type')!r},"
        f" meta charset {meta['charset'] if meta else None!r}, decoded as {resp.encoding},"
        f" title {title[:60]!r}, inputs {inputs}, tables {len(soup.find_all('table'))},"
        f" captcha mentioned {'captcha' in resp.text.lower()}"
    ]
    if resp.url.host == SSO_HOST:
        errors = (_text(e) for c in SSO_ERROR_CLASSES for e in soup.find_all(class_=c))
        lines.append(f"  sso error {next((e for e in errors if e), None)!r}")
    if structure:
        sources, urls, named = _scripts(soup)
        lines.append(f"  scripts {sources}, inline urls {urls}, {ADVISOR} in inline scripts {named}")
        lines.append(f"  skeleton {_skeleton(soup.body or soup)}")
    print(_redact("\n".join(lines), student_id), file=sys.stderr)


def _fail(reason: str, resp: httpx.Response | None, student_id: str) -> int:
    print(f"[FAIL] {reason}", file=sys.stderr)
    if resp is not None:
        _describe(resp, student_id, structure=True)
    return 3


# ---------------- flow ----------------

def _run(
    bridge: NtustSsoBridge, student_id: str, show: bool, last: list[httpx.Response],
) -> int:
    # The portal answers without a session; the sign-in is the records system's own.
    portal = bridge.open(SUBSYSTEM_URL_ZH)
    links = [link for group in parse_subsystems(portal.text) or [] for link in group["links"]]
    records = next((link["url"] for link in links if RECORDS_SYSTEM in link["name"]), None)
    if records is None:
        return _fail(f"no {RECORDS_SYSTEM} among {len(links)} portal links", portal, student_id)
    last.clear()
    if not bridge.ensure_service_login(urljoin(str(portal.url), records)):
        return _fail("SSO sign-in did not pass the login page", next(iter(last), None), student_id)

    # The sign-in ends on the system's home page; opening the system again reruns its OIDC round.
    home = last[0]
    view = _link(home, RECORDS_VIEW)
    if view is None:
        return _fail(f"no {RECORDS_VIEW} link", home, student_id)

    page = bridge.open(view)
    result = parse_advisors(page.text)
    if result is None:
        return _fail("no table with a <th> row naming 導師", page, student_id)
    _describe(page, student_id, structure=False)
    host = page.url.host
    sent = [c for c in bridge.client.cookies.jar if host.endswith(c.domain.lstrip("."))]
    print(
        f"  cookies for {host}: {len(sent)},"
        f" {sum(len(c.name) + len(c.value) + 2 for c in sent)} bytes",
        file=sys.stderr,
    )
    print(json.dumps(shown(result, show), ensure_ascii=False, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="python -m api.ntust.student_advisors")
    parser.add_argument("--show", action="store_true", help="print advisor names in full")
    args = parser.parse_args()
    # A failed sign-in logs a traceback whose URLs carry the OIDC query; the trace says enough.
    logging.getLogger("api.ntust.sso").setLevel(logging.CRITICAL)
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    last: list[httpx.Response] = []
    with NtustSsoBridge(sid, pwd, db_path=":memory:") as bridge:
        bridge.client.event_hooks = {"response": [_trace(sid, last)]}
        try:
            return _run(bridge, sid, args.show, last)
        except httpx.HTTPStatusError as e:
            print(
                f"[FAIL] HTTP {e.response.status_code} at"
                f" {e.request.url.host}{_path(e.request.url, sid)}",
                file=sys.stderr,
            )
        except httpx.HTTPError as e:
            print(f"[FAIL] {type(e).__name__}", file=sys.stderr)
    return 3


def _self_check() -> None:
    assert mask("王小明") == "王○○"
    assert mask("A") == "A" and mask("") == ""
    assert parse_advisors("<html><form id='loginForm'></form></html>") is None

    # Made-up names. A key-value row naming 導師 sits above the semester table, and a layout
    # table wraps it; neither may be read as the table.
    page = """
    <ul class="navbar-right"><li><a class="nav-link" href="#">測試生</a></li></ul>
    <div class="box"><div class="box-body">
      <table class="table"><tr><th>姓名</th><td>測試生</td><th>導師</th><td>陳大文</td></tr></table>
    </div></div>
    <table class="layout"><tr><td>
      <div class="box"><div class="box-body">
        <table class="table">
          <thead><tr><th>學年度</th><th>學期</th><th>導師</th></tr></thead>
          <tbody>
            <tr><td>113</td><td>1</td><td>王小明</td></tr>
            <tr><td>113</td><td>2</td><td>李 大華</td></tr>
            <tr><td colspan="3">備註</td></tr>
          </tbody>
        </table>
      </div></div>
    </td></tr></table>
    """
    result = parse_advisors(page)
    assert result == {
        "headers": ["學年度", "學期", "導師"],
        "rows": [
            {"semester": "113 1", "advisor": "王小明"},
            {"semester": "113 2", "advisor": "李 大華"},
        ],
    }, result
    assert shown(result, show=False) == {
        "headers": ["學年度", "學期", "導師"],
        "row_count": 2,
        "rows": [
            {"semester": "113 1", "advisor": "王○○"},
            {"semester": "113 2", "advisor": "李○○○"},
        ],
    }
    assert shown(result, show=True)["rows"][0] == {"semester": "113 1", "advisor": "王小明"}

    # A key-value row naming 導師 is no header row; its values would print as headers.
    assert parse_advisors("<table><tr><th>導師</th><td>陳大文</td></tr></table>") is None

    # A table with headers and no semesters is [], not None.
    empty = "<table><tr><th>學年期</th><th>導師</th></tr><tr><td colspan='2'>查無資料</td></tr></table>"
    assert parse_advisors(empty) == {"headers": ["學年期", "導師"], "rows": []}

    # A semester cell that is not a semester is masked like a name.
    odd = shown({"headers": ["學期導師"], "rows": [{"semester": "王小明", "advisor": "王小明"}]}, False)
    assert odd["rows"] == [{"semester": "王○○", "advisor": "王○○"}], odd

    assert _path(httpx.URL("https://h.example/a/B00000000/x?code=c"), "b00000000") == "/a/<id>/x"
    assert _path(httpx.URL("https://h.example/s/" + "t" * TOKEN_LENGTH), "b00000000") == "/s/<token>"

    # The skeleton keeps selectors and text kinds, never the text, and folds equal neighbours.
    block = BeautifulSoup(
        '<div class="tutors"><h5>導師</h5>'
        '<div class="row"><span>1131</span><span>王小明</span></div>'
        '<div class="row"><span>1132</span><span>李大華</span></div>'
        '<input name="StudentName" value="測試生"><script>var x = "陳大文";</script></div>',
        "html.parser",
    )
    skeleton = _skeleton(block.div)
    assert skeleton == "div.tutors[h5:c2* div.row[span:d4 span:c3]x2 input@StudentName:c3]", skeleton
    scripts = BeautifulSoup(
        '<script src="/lib/grid.js?v=1"></script>'
        '<script>$.get("/StudentInformation/Information/Tutors?id=1"); var c = "導師";</script>',
        "html.parser",
    )
    assert _scripts(scripts) == (
        ["/lib/grid.js"], ["/StudentInformation/Information/Tutors"], True,
    ), _scripts(scripts)
    print("self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        sys.exit(0)
    sys.exit(main())
