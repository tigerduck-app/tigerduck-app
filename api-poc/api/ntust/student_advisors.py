"""Each semester's advisor (導師), from the student records system (學籍管理系統).

The portal page (`subsystem.py`) answers without a session and links 學籍管理系統 at
`stuinfosys.ntust.edu.tw/StudentInformation`, which signs in through ssoam2's OIDC and gets the
code back by a form_post page that `NtustSsoBridge` submits. The sign-in ends on `Home/Index`,
whose menu links 學籍資料檢視 (`Information/Index`, UTF-8); opening the system's root again runs
the OIDC round once more, signed in or not. After the sign-in the jar sends this host 6 cookies,
about 6.5 KB with SSO's own, toward IIS's 16 KB request header limit
(`BrowserSchoolSites.cookieBudget`).

學籍資料檢視 has no `<table>` and loads nothing by script. The record is a Bootstrap form: one
`div.form-group` per field, a `label.control-label` and a named `input.form-control`. Its last
group is the advisors: a label naming 導師 and one unnamed read-only input per semester, whose
value is a sentence holding the term and the advisor's name.

The page is the student's own record: the probe prints only the advisor rows, each name and the
label cut to their first character unless `--show` is passed. Stderr holds the request trace
(method, host, path, status; session-like segments blanked), the title's length, ssoam2's
refusal (redacted, 80 characters at most), each advisor value's format with its data hidden,
and on a miss the page's skeleton (selectors and the kind and length of each leaf's text, never
a field's value) with its scripts' paths. Any other failure prints its exception's type alone.
Cookies stay in memory.
"""

from __future__ import annotations

import argparse
import contextlib
import io
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
# 113 學年度 第 1 學期, 114學年度下學期, 1141學期: the ROC year, then the term.
TERM = re.compile(r"(\d{2,3})\s*(?:學年度?\s*第?\s*([12一二上下])\s*學期|([12])\s*學期)")
TERM_DIGITS = {"一": "1", "上": "1", "二": "2", "下": "2"}
# What may stand between 導師 and the name: 導師為：, 導師是, 導師 : .
CONNECTIVE = re.compile(r"\s*[為是]?\s*[:：]?\s*")
TITLE = re.compile(r"\s*(?:助理教授|副教授|教授|講師|老師)$")
# What a semester may be to be printed as is; anything else is masked like a name.
SEMESTER_SHAPE = re.compile(r"\d{2,3}[12]")
# The sentence's own words, which a value's printed format keeps; longer words first.
SENTENCE_WORDS = ("助理教授", "副教授", "學年度", "學年", "學期", "導師", "教授", "講師", "老師", "第")
SSO_HOST = "ssoam2.ntust.edu.tw"
# Where ssoam2 writes why it refused a sign-in, as HTMLParser.loginErrorMessage reads it.
SSO_ERROR_CLASSES = ("field-validation-error", "validation-summary-errors", "alert-danger", "text-danger")
SSO_ERROR_LENGTH = 80
# A path segment this long is a token, not a page name.
TOKEN_LENGTH = 24
# A segment carrying a session: a ;jsessionid= style parameter, or ASP.NET's cookieless (S(...)).
SESSION_SEGMENT = re.compile(r";|\([A-Z]\(")
HAN = range(0x4E00, 0xA000)
SKELETON_DEPTH = 16
UNSHOWN_TAGS = frozenset({"head", "script", "style", "svg", "noscript"})
FIELD_TAGS = frozenset({"input", "textarea", "select"})
# A quoted path or address in a script, cut before any query.
URL_LITERAL = re.compile(r"""["'`](/[\w/.-]+|https?://[^"'`\s?]+)""")


def mask(name: str) -> str:
    """王小明 -> 王○○."""
    return name[:1] + "○" * (len(name) - 1)


def _text(node: Tag) -> str:
    return " ".join(node.get_text(" ", strip=True).split())


def _advisor_group(soup: BeautifulSoup) -> tuple[str, list[str]] | None:
    """The last label naming 導師 and the values of its group's unnamed inputs.

    The record's own fields are named inputs; each semester's advisor is an unnamed read-only
    input in the label's form group, so named inputs are never read.
    """
    label = next((tag for tag in reversed(soup.find_all("label")) if ADVISOR in _text(tag)), None)
    group = label.find_parent(class_="form-group") if label else None
    if group is None:
        return None
    values = [i.get("value", "").strip() for i in group.find_all("input") if not i.get("name")]
    return _text(label), [v for v in values if v]


def _semester_advisor(value: str) -> dict[str, str]:
    """One semester's sentence as a term code (1131) and the advisor's name."""
    term = TERM.search(value)
    digit = (term.group(2) or term.group(3)) if term else ""
    semester = term.group(1) + TERM_DIGITS.get(digit, digit) if term else ""
    before, _, after = value.partition(ADVISOR)
    after = after[CONNECTIVE.match(after).end():]
    name = re.split(r"[（(]", after, maxsplit=1)[0]
    name = TITLE.sub("", name.strip(" ，,。."))
    if not name:
        # 王小明導師: the name runs from the term's last word to 導師.
        name = re.split(r"學期|學年度?", before)[-1].strip(" :：")
    return {"semester": semester, "advisor": name}


def parse_advisors(html: str) -> dict[str, object] | None:
    """The 導師 label and one semester/advisor row per input of its group.

    None when no label in a form group names 導師 (a sign-in page, a redesign), which is not
    the same as a group with no inputs.
    """
    found = _advisor_group(BeautifulSoup(html, "html.parser"))
    if found is None:
        return None
    label, values = found
    return {"label": label, "rows": [_semester_advisor(v) for v in values]}


def shown(result: dict[str, object], show: bool) -> dict[str, object]:
    """The parsed rows as printed: names and the label masked unless `show`."""
    rows = [
        {
            "semester": row["semester"]
            if show or SEMESTER_SHAPE.fullmatch(row["semester"]) else mask(row["semester"]),
            "advisor": row["advisor"] if show else mask(row["advisor"]),
        }
        for row in result["rows"]
    ]
    label = result["label"] if show else mask(result["label"])
    return {"label": label, "row_count": len(rows), "rows": rows}


def _template(value: str) -> str:
    """A value's format without its data: the sentence's words kept, other Han ○, digits 9."""
    out, i = [], 0
    while i < len(value):
        word = next((w for w in SENTENCE_WORDS if value.startswith(w, i)), None)
        if word:
            out.append(word)
            i += len(word)
            continue
        ch = value[i]
        out.append("○" if ord(ch) in HAN else "9" if ch.isdigit() else "a" if ch.isalpha() else ch)
        i += 1
    return "".join(out)


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


def _blank(path: str) -> str:
    return "/".join(
        "<token>" if len(s) >= TOKEN_LENGTH or SESSION_SEGMENT.search(s) else s
        for s in path.split("/")
    )


def _path(url: httpx.URL, student_id: str) -> str:
    """The URL's path, never its query, with the student ID and session-like segments blanked."""
    return _blank(_redact(url.path, student_id))


def _address(text: str) -> str:
    """A script's address as host and blanked path, never its query."""
    try:
        url = httpx.URL(text)
    except httpx.InvalidURL:
        return "<url>"
    return f"{url.host}{_blank(url.path)}"


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
    """Text as its kind and length: c Han, d digits, x other, e empty; `*` marks 導師, `#` a term."""
    if not text:
        return "e"
    if text.isdigit():
        kind = "d"
    elif all(ord(ch) in HAN for ch in text):
        kind = "c"
    else:
        kind = "x"
    return (
        f"{kind}{len(text)}"
        + ("*" if ADVISOR in text else "")
        + ("#" if any(label in text for label in SEMESTER_LABELS) else "")
    )


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
    if el.name in FIELD_TAGS and el.get("name"):
        # A field of the record: its name says what it is, and its value is the student's.
        return _selector(el)
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
    sources = [_address(s["src"]) for s in soup.find_all("script", src=True)]
    inline = "\n".join(s.get_text() for s in soup.find_all("script") if not s.get("src"))
    return sources, sorted({_address(u) for u in URL_LITERAL.findall(inline)}), ADVISOR in inline


def _describe(resp: httpx.Response, student_id: str, structure: bool) -> None:
    soup = BeautifulSoup(resp.text, "html.parser")
    meta = soup.find("meta", charset=True)
    title = _text(soup.title) if soup.title else ""
    inputs = sorted({i["name"] for i in soup.find_all("input", attrs={"name": True})})
    lines = [
        f"  page {resp.url.host}{_path(resp.url, student_id)} {resp.status_code},"
        f" content-type {resp.headers.get('content-type')!r},"
        f" meta charset {meta['charset'] if meta else None!r}, decoded as {resp.encoding},"
        f" title {len(title)} chars, inputs {inputs}, tables {len(soup.find_all('table'))},"
        f" captcha mentioned {'captcha' in resp.text.lower()}"
    ]
    if resp.url.host == SSO_HOST:
        errors = (_text(e) for c in SSO_ERROR_CLASSES for e in soup.find_all(class_=c))
        # Redacted before the cut, which could otherwise leave part of the student ID.
        error = _redact(next((e for e in errors if e), ""), student_id)[:SSO_ERROR_LENGTH]
        lines.append(f"  sso error {error!r}")
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

    return _present(bridge.open(view), student_id, show)


def _present(page: httpx.Response, student_id: str, show: bool) -> int:
    """Prints the advisor rows of 學籍資料檢視, or fails with the page's skeleton."""
    result = parse_advisors(page.text)
    if result is None:
        return _fail(f"no label naming {ADVISOR} in a form group", page, student_id)
    if not result["rows"]:
        return _fail(f"no semester under the {ADVISOR} label", page, student_id)
    _describe(page, student_id, structure=False)
    _, values = _advisor_group(BeautifulSoup(page.text, "html.parser"))
    print(_redact(f"  value formats {[_template(v) for v in values]}", student_id), file=sys.stderr)
    print(json.dumps(shown(result, show), ensure_ascii=False, indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m api.ntust.student_advisors")
    parser.add_argument("--show", action="store_true", help="print advisor names in full")
    args = parser.parse_args(argv)
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
        except Exception as e:
            # Only the type: an InvalidURL's or a network error's text can quote the OIDC code.
            print(f"[FAIL] {type(e).__name__}", file=sys.stderr)
    return 3


def _self_check() -> None:
    assert mask("王小明") == "王○○"
    assert mask("A") == "A" and mask("") == ""
    assert parse_advisors("<html><form id='loginForm'></form></html>") is None

    # Made-up data in the page's structure: the record's named fields, a checkbox group, then
    # the advisor group, one unnamed read-only input per semester.
    page = """
    <form id="logoutForm" method="post" action="/StudentInformation/Account/Logout">
      <input name="__RequestVerificationToken" type="hidden" value="t">
      <ul class="nav navbar-nav navbar-right"><li class="mr-3"><a><span class="text-success">測試生</span></a></li></ul>
    </form>
    <div class="container border"><div class="row justify-content-center">
      <div class="col-sm-12"><div class="form-group">
        <label class="control-label col-sm-2 font-weight-bold text-info">學號</label>
        <div class="col-sm-10"><input class="form-control text-box single-line" id="StudentNo" name="StudentNo" type="text" value="B00000000"></div>
      </div></div>
      <div class="col-sm-12"><div class="form-group">
        <label class="control-label col-sm-2 font-weight-bold text-info">學生姓名</label>
        <div class="col-sm-10"><input class="form-control text-box single-line" id="StudentName" name="StudentName" type="text" value="測試生"></div>
      </div></div>
      <div class="col-sm-12"><div class="form-group">
        <label class="control-label col-sm-2 font-weight-bold text-info">身分類別</label>
        <div class="col-sm-10"><div class="ml-3"><div class="form-check form-check-inline">
          <input class="form-check-input" type="checkbox"><label class="form-check-label">一般生</label>
        </div></div></div>
      </div></div>
      <div class="col-sm-12"><div class="form-group">
        <label class="control-label col-sm-2 font-weight-bold text-info">歷屆導師</label>
        <div class="col-sm-10">
          <input class="form-control" type="text" value="113 學年度第 1 學期 導師為：王小明老師" readonly>
          <input class="form-control" type="text" value="113 學年度第 2 學期 導師為：王小明老師" readonly>
          <input class="form-control" type="text" value="114 學年度第 1 學期 導師為：李大華老師" readonly>
        </div>
      </div></div>
    </div></div>
    <div class="container mt-2"><div class="row justify-content-center"></div></div>
    """
    result = parse_advisors(page)
    assert result == {
        "label": "歷屆導師",
        "rows": [
            {"semester": "1131", "advisor": "王小明"},
            {"semester": "1132", "advisor": "王小明"},
            {"semester": "1141", "advisor": "李大華"},
        ],
    }, result
    assert shown(result, show=False) == {
        "label": "歷○○○",
        "row_count": 3,
        "rows": [
            {"semester": "1131", "advisor": "王○○"},
            {"semester": "1132", "advisor": "王○○"},
            {"semester": "1141", "advisor": "李○○"},
        ],
    }
    assert shown(result, show=True)["label"] == "歷屆導師"
    assert shown(result, show=True)["rows"][2] == {"semester": "1141", "advisor": "李大華"}

    # The sentence spelt without spaces, with a 上/下 term, another title, a department after
    # the name, or the name before 導師.
    def one(value: str) -> dict[str, str]:
        group = (
            '<div class="form-group"><label class="control-label">歷年導師</label>'
            f'<div class="col-sm-10"><input class="form-control" value="{value}"></div></div>'
        )
        return parse_advisors(group)["rows"][0]

    assert one("113學年度第2學期導師：李大華") == {"semester": "1132", "advisor": "李大華"}
    assert one("114學年度下學期 導師:陳大文 老師") == {"semester": "1142", "advisor": "陳大文"}
    assert one("1141學期 導師：陳大文（資工系）") == {"semester": "1141", "advisor": "陳大文"}
    assert one("113學年度第1學期王小明導師") == {"semester": "1131", "advisor": "王小明"}
    # 為 and 是 are connectives only right after 導師; a name may begin with either.
    assert one("113學年度第1學期導師：是小明") == {"semester": "1131", "advisor": "是小明"}

    # A named input in the group is a field of the record, never a semester.
    named = (
        '<div class="form-group"><label>歷年導師</label><input name="TutorId" value="T0001">'
        '<input class="form-control" value="113學年度第1學期導師：王小明"></div>'
    )
    assert parse_advisors(named)["rows"] == [{"semester": "1131", "advisor": "王小明"}]

    # A value's printed format keeps the sentence's words and hides its data.
    assert _template("113 學年度第 1 學期 導師為：王小明老師") == "999 學年度第 9 學期 導師○：○○○老師"
    assert _template("1141學期導師:Ann Lee 副教授") == "9999學期導師:aaa aaa 副教授"

    # No 導師 label is a missing block (a sign-in page, a redesign); a label with no inputs is
    # a record with no advisors yet.
    assert parse_advisors('<label class="control-label">學號</label><input value="1">') is None
    empty = '<div class="form-group"><label>歷年導師</label><div class="col-sm-10"></div></div>'
    assert parse_advisors(empty) == {"label": "歷年導師", "rows": []}
    # A label outside a form group is no advisor block; its parent may hold anything.
    loose = '<div><label>歷屆導師</label><input value="113學年度第1學期導師：王小明"></div>'
    assert parse_advisors(loose) is None

    # A semester that is not a term code is masked like a name.
    odd = shown({"label": "導師", "rows": [{"semester": "王小明", "advisor": "王小明"}]}, False)
    assert odd["rows"] == [{"semester": "王○○", "advisor": "王○○"}], odd

    sid = "b00000000"
    assert _path(httpx.URL("https://h.example/a/B00000000/x?code=c"), sid) == "/a/<id>/x"
    # Segments that carry a session: 24 or more characters, a ;jsessionid=, ASP.NET's (S(...)).
    assert _path(httpx.URL("https://h.example/s/" + "t" * 24), sid) == "/s/<token>"
    assert _path(httpx.URL("https://h.example/app/page.jsp;jsessionid=A1/x"), sid) == "/app/<token>/x"
    assert _path(httpx.URL("https://h.example/(S(abcdef))/a.aspx"), sid) == "/<token>/a.aspx"
    kept = "/StudentInformation/Account/OpenIDCallback"
    assert _path(httpx.URL("https://h.example" + kept), sid) == kept

    # The skeleton keeps selectors and text kinds, never the text, and folds equal neighbours.
    block = BeautifulSoup(
        '<div class="tutors"><h5>導師</h5>'
        '<div class="row"><span>1131</span><span>王小明</span></div>'
        '<div class="row"><span>1132</span><span>李大華</span></div>'
        '<input name="StudentName" value="測試生"><script>var x = "陳大文";</script></div>',
        "html.parser",
    )
    skeleton = _skeleton(block.div)
    assert skeleton == "div.tutors[h5:c2* div.row[span:d4 span:c3]x2 input@StudentName]", skeleton
    scripts = BeautifulSoup(
        '<script src="/lib/grid.js?v=1"></script>'
        '<script>$.get("/StudentInformation/Information/Tutors?id=1"); var c = "導師";</script>',
        "html.parser",
    )
    assert _scripts(scripts) == (
        ["/lib/grid.js"], ["/StudentInformation/Information/Tutors"], True,
    ), _scripts(scripts)
    session_scripts = BeautifulSoup(
        '<script src="/(S(abcdef))/app.js?v=2"></script>'
        '<script>location = "https://h.example/s/' + "t" * TOKEN_LENGTH + '/next";</script>',
        "html.parser",
    )
    assert _scripts(session_scripts) == (
        ["/<token>/app.js"], ["h.example/s/<token>/next"], False,
    ), _scripts(session_scripts)

    def captured(run: Callable[[], object]) -> tuple[object, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = run()
        return rc, out.getvalue(), err.getvalue()

    def answer(html: str, url: str) -> httpx.Response:
        return httpx.Response(200, html=html, request=httpx.Request("GET", url))

    view = "https://stuinfosys.ntust.edu.tw/StudentInformation/Information/Index"
    made_up = ("測試生", "王小明", "李大華", "B00000000")

    # A 導師 label with no semesters fails with the skeleton instead of printing no rows.
    rc, out, err = captured(lambda: _present(answer(empty, view), sid, False))
    assert rc == 3 and out == "" and "[FAIL]" in err and "skeleton" in err, (rc, out, err)

    # The page prints masked rows on stdout; stderr holds the title's length, never its text,
    # and none of the record's values.
    title = "學籍資料檢視 - 國立臺灣科技大學 學籍管理"
    full = f"<html><head><title>{title}</title></head><body>{page}</body></html>"
    rc, out, err = captured(lambda: _present(answer(full, view), sid, False))
    assert rc == 0 and json.loads(out) == shown(result, show=False), (rc, out)
    assert f"title {len(title)} chars" in err and title not in err, err
    assert not any(word in out + err for word in made_up), (out, err)

    # ssoam2's refusal prints redacted and at most SSO_ERROR_LENGTH characters long.
    refusal = "帳號 B00000000 " + "錯" * 100
    login = answer(
        f'<form id="loginForm"></form><div class="validation-summary-errors">{refusal}</div>',
        "https://ssoam2.ntust.edu.tw/account/login",
    )
    _, _, err = captured(lambda: _describe(login, sid, structure=False))
    line = next(text for text in err.splitlines() if "sso error" in text)
    assert "<id>" in line and "B00000000" not in err and line.count("錯") < SSO_ERROR_LENGTH, line

    # Any other failure prints its type alone: an InvalidURL's text can quote the OIDC code.
    def leaky(*_: object) -> int:
        raise httpx.InvalidURL("https://h.example/signin-oidc?code=SECRET&state=S")

    real = globals()["_run"], globals()["load_creds"]
    globals()["_run"], globals()["load_creds"] = leaky, lambda: ("B00000000", "pw")
    try:
        rc, out, err = captured(lambda: main([]))
    finally:
        globals()["_run"], globals()["load_creds"] = real
    assert rc == 3 and out == "" and err.strip() == "[FAIL] InvalidURL", (rc, err)
    print("self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        sys.exit(0)
    sys.exit(main())
