"""Classroom occupancy probe for cour01.ntust.edu.tw (room booking system).

The site answers "what is each room doing today" as an ASP.NET WebForms
DataGrid. Three things bite, in the order you hit them.

## 1. OIDC with response_mode=form_post

`classroom_usecondition.aspx` bounces straight into the handshake, so there is
no need to enter through `Index.aspx`. The last leg is the catch: ssoam2 does
not 302 the authorization code back. It returns an HTML page holding a
self-submitting form, so following redirects alone never reaches the end —
that form has to be POSTed explicitly. A form is only the bridge when it
carries `code` or `id_token`; the "please log in again" page also has an
action and a pile of inputs, and mistaking it for the bridge turns an expired
session into a parse failure further down.

Cookies must be attached at *every* hop of the chain, not just the first
request: the leg towards ssoam2 needs `AuthServer`, and `SSO_login.aspx` sets
`OpenIdConnect.nonce.*` which `signin-oidc` needs to validate the code. httpx
carries the jar through redirects, so `follow_redirects=True` is safe here.

## 2. Postback order is not optional

The building dropdown is empty on the freshly loaded page. Posting a building
code before the campus has been chosen fails `__EVENTVALIDATION`, and the site
answers with an **HTTP 500 runtime error page** rather than an empty result —
which parses as "no grid" and looks like a transient failure. Select the
campus first so the site renders the building options; after that the campus,
building and date can all ride in one postback.

The ASP.NET Calendar's postback argument is days since 2000-01-01, computed in
UTC so a DST boundary cannot shift it by a day.

The ViewState survives reuse: repeated queries for different buildings and
dates on the same session work, so the campus-selected page is worth keeping.
Failure is benign — the site returns a page with no grid and the caller can
redo the handshake.

## 3. The grid

Paging targets look like `showinfo_grd$_ctl54$_ctl1`, and the middle number is
derived from the row count — it becomes `_ctl42` on page two. It has to be
read out of the pager HTML, never hardcoded.

A cell's text is the course name and the teacher run together with no
separator of any kind — the grid contains no `<br>` at all — so the raw
string is reported rather than split on a guess.

`parse_grid` distinguishes two things that must not collapse into one value:
no grid at all (`None`, a failure — a login page or the 500 error page) versus
a grid with no data rows (`[]`, legitimate — the site returns nothing at all
for weekends, which is not the same as "everything is free").
"""

from __future__ import annotations

import json
import logging
import re
import sys
from datetime import date, datetime, timezone
from typing import Any

import httpx
from bs4 import BeautifulSoup

from api import load_creds
from api.ntust.sso import NtustSsoBridge

HOST = "https://cour01.ntust.edu.tw"
QUERY_URL = f"{HOST}/classroom_user/classroom_usecondition.aspx"

CAMPUS_SELECT = "DropdownCampusListID"
BUILDING_SELECT = "DropDownBuildingListID"
CALENDAR_ID = "date_cal"
GRID_ID = "showinfo_grd"

SECTION_COUNT = 14
CALENDAR_EPOCH = datetime(2000, 1, 1, tzinfo=timezone.utc)
MAX_PAGES = 20

DO_POSTBACK = re.compile(r"__doPostBack\('([^']*)','([^']*)'\)")

logger = logging.getLogger(__name__)


# ---------------- pure helpers ----------------

def day_argument(when: date) -> str:
    """ASP.NET Calendar postback argument: days since 2000-01-01, in UTC."""
    utc = datetime(when.year, when.month, when.day, tzinfo=timezone.utc)
    return str((utc - CALENDAR_EPOCH).days)


def is_query_page(html: str) -> bool:
    return CAMPUS_SELECT in html


def form_fields(html: str) -> dict[str, str]:
    """Everything the form would submit, __VIEWSTATE and friends included."""
    soup = BeautifulSoup(html, "html.parser")
    form = soup.find("form")
    fields: dict[str, str] = {}
    if not form:
        return fields

    for inp in form.find_all("input"):
        name = inp.get("name")
        if not name:
            continue
        kind = (inp.get("type") or "text").lower()
        if kind in ("submit", "button", "image"):
            continue
        # Unchecked boxes are not submitted by a browser either.
        if kind in ("checkbox", "radio") and not inp.has_attr("checked"):
            continue
        fields[name] = inp.get("value", "")

    for select in form.find_all("select"):
        name = select.get("name")
        if not name:
            continue
        options = select.find_all("option")
        chosen = next(
            (o for o in options if o.has_attr("selected")),
            options[0] if options else None,
        )
        fields[name] = chosen.get("value", "") if chosen else ""
    return fields


def parse_options(html: str, name: str) -> list[dict[str, str]]:
    """Dropdown options, minus the empty-valued "please choose" entry."""
    soup = BeautifulSoup(html, "html.parser")
    select = soup.find("select", attrs={"name": name})
    if not select:
        return []
    out = []
    for option in select.find_all("option"):
        code = option.get("value", "")
        if not code:
            continue
        out.append({"code": code, "name": option.get_text(strip=True)})
    return out


def _direct_rows(table) -> list:
    """Direct <tr> children, stepping through the tbody the parser inserts.

    Not `table.find_all("tr")`: each cell holds a nested table whose rows
    would come along for the ride.
    """
    rows = []
    for child in table.find_all(recursive=False):
        if child.name == "tr":
            rows.append(child)
        elif child.name in ("tbody", "thead", "tfoot"):
            rows.extend(c for c in child.find_all(recursive=False) if c.name == "tr")
    return rows


def _parse_slot(cell) -> dict[str, Any]:
    """One slot: the cell's own text, plus whether the site marked it.

    Every cell holds a nested `<table style="height:16px;width:80px">` with a
    single empty `<td>`. It is a fixed-size placeholder, so only a fill
    (`bgcolor`, or `background` in the style) is a mark — the dimensions are
    not a signal. No marked cell was observed while writing this, so treat
    `marked` as unconfirmed until one turns up.

    Only the cell's *direct* text nodes are read; `get_text()` would fold the
    nested table's whitespace into the course name.

    The site writes course and teacher as one run of text with **no
    separator** (`表達與經典閱讀楊穎詩` is a single text node, and there is not
    one `<br>` in the whole grid). They cannot be split without a course
    catalogue to match against, so the raw string is reported as-is.
    """
    text = ""
    for node in cell.children:
        if isinstance(node, str):
            text += node
        elif getattr(node, "name", None) == "br":
            text += " "
    text = re.sub(r"\s+", " ", text).strip()

    marked = False
    for node in cell.find_all(["table", "td"]):
        style = node.get("style", "") or ""
        if node.has_attr("bgcolor") or "background" in style:
            marked = True
            break

    return {"text": text, "marked": marked}


def parse_grid(html: str) -> list[dict[str, Any]] | None:
    """Room rows, or None when the grid is absent (see module docstring)."""
    soup = BeautifulSoup(html, "html.parser")
    grid = soup.find(id=GRID_ID)
    if grid is None:
        return None
    rows = _direct_rows(grid)
    if not rows:
        return None

    out = []
    # First row is the header, last is the pager; rooms are in between.
    for row in rows[1:]:
        cells = [c for c in row.find_all(recursive=False) if c.name == "td"]
        # The pager row is a single colspan cell, so a column-count mismatch
        # means this is not a data row.
        if len(cells) != SECTION_COUNT + 1:
            continue
        name = cells[0].get_text(strip=True)
        if not name:
            continue
        out.append({
            "name": name,
            "slots": [_parse_slot(c) for c in cells[1:]],
        })
    return out


def parse_pager_target(html: str, page: int) -> tuple[str, str] | None:
    """Postback target for `page`, read from the pager — never hardcoded."""
    soup = BeautifulSoup(html, "html.parser")
    grid = soup.find(id=GRID_ID)
    if grid is None:
        return None
    rows = _direct_rows(grid)
    if not rows:
        return None
    for link in rows[-1].find_all("a"):
        if link.get_text(strip=True) != str(page):
            continue
        m = DO_POSTBACK.search(link.get("href", ""))
        if m:
            return m.group(1), m.group(2)
    return None


def find_form_post_bridge(html: str) -> tuple[str, dict[str, str]] | None:
    """The OIDC response_mode=form_post page, or None if this is not one."""
    soup = BeautifulSoup(html, "html.parser")
    for form in soup.find_all("form"):
        action = (form.get("action") or "").strip()
        if not action:
            continue
        fields = {
            i.get("name"): i.get("value", "")
            for i in form.find_all("input") if i.get("name")
        }
        # Only an authorization code counts; the login page also has an action
        # and plenty of inputs.
        if "code" in fields or "id_token" in fields:
            return action, fields
    return None


# ---------------- client ----------------

class ClassroomClient:
    def __init__(self, bridge: NtustSsoBridge) -> None:
        self._http = bridge.client
        self._campus_page: dict[str, str] = {}

    def open_query_page(self) -> str | None:
        """Complete the handshake and return the query page, or None."""
        resp = self._http.get(QUERY_URL)
        if is_query_page(resp.text):
            return resp.text

        bridge = find_form_post_bridge(resp.text)
        if bridge is None:
            logger.info("No authorization-code form; the SSO session expired.")
            return None
        action, fields = bridge
        posted = self._http.post(action, data=fields, headers={"Referer": QUERY_URL})
        if is_query_page(posted.text):
            return posted.text
        # signin-oidc's 302 usually lands back on the page that started the
        # handshake; ask once more if it did not.
        again = self._http.get(QUERY_URL)
        return again.text if is_query_page(again.text) else None

    def _postback(
        self,
        html: str,
        target: str,
        argument: str = "",
        values: dict[str, str] | None = None,
    ) -> str:
        fields = form_fields(html)
        fields.update(values or {})
        fields["__EVENTTARGET"] = target
        fields["__EVENTARGUMENT"] = argument
        resp = self._http.post(
            QUERY_URL, data=fields, headers={"Referer": QUERY_URL},
        )
        # A 500 here is the __EVENTVALIDATION failure described above; it is
        # returned as a readable page, so do not raise on it.
        if resp.status_code >= 500:
            logger.warning("cour01 answered %s — postback order wrong?", resp.status_code)
        return resp.text

    def campuses(self) -> list[dict[str, Any]] | None:
        """Campuses and their buildings — one postback per campus."""
        page = self.open_query_page()
        if page is None:
            return None
        out = []
        for campus in parse_options(page, CAMPUS_SELECT):
            selected = self._postback(
                page, CAMPUS_SELECT, values={CAMPUS_SELECT: campus["code"]},
            )
            if not is_query_page(selected):
                logger.error("Campus %s did not return the query page", campus["code"])
                return None
            self._campus_page[campus["code"]] = selected
            out.append({
                **campus,
                "buildings": parse_options(selected, BUILDING_SELECT),
            })
        return out or None

    def usage(
        self,
        campus_code: str,
        when: date,
        building_code: str | None = None,
    ) -> dict[str, Any] | None:
        result = self._fetch_usage(campus_code, when, building_code)
        if result is not None:
            return result
        # The cached ViewState may have gone stale; drop it and retry once.
        if self._campus_page.pop(campus_code, None) is None:
            return None
        logger.info("ViewState stale, redoing the handshake")
        return self._fetch_usage(campus_code, when, building_code)

    def _fetch_usage(
        self,
        campus_code: str,
        when: date,
        building_code: str | None,
    ) -> dict[str, Any] | None:
        page = self._campus_page.get(campus_code)
        if page is None:
            opened = self.open_query_page()
            if opened is None:
                return None
            page = self._postback(
                opened, CAMPUS_SELECT, values={CAMPUS_SELECT: campus_code},
            )
            if not is_query_page(page):
                return None
            self._campus_page[campus_code] = page

        # Calendar, campus and building go out together: the calendar is the
        # event, the other two ride along as form values.
        values = {CAMPUS_SELECT: campus_code}
        if building_code:
            values[BUILDING_SELECT] = building_code
        html = self._postback(
            page, CALENDAR_ID, argument=day_argument(when), values=values,
        )

        rooms: list[dict[str, Any]] = []
        for page_index in range(1, MAX_PAGES + 1):
            parsed = parse_grid(html)
            if parsed is None:
                return None
            rooms.extend(parsed)
            nxt = parse_pager_target(html, page_index + 1)
            if nxt is None:
                break
            html = self._postback(html, nxt[0], argument=nxt[1])

        return {
            "campus": campus_code,
            "building": building_code,
            "date": when.isoformat(),
            "sections": SECTION_COUNT,
            "rooms": rooms,
        }


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s - %(message)s")
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    argv = sys.argv[1:]
    campus = argv[0] if argv else None
    building = argv[1] if len(argv) > 1 else None
    when = date.fromisoformat(argv[2]) if len(argv) > 2 else date.today()

    with NtustSsoBridge(sid, pwd) as bridge:
        if not bridge.ensure_service_login(QUERY_URL):
            print("[FAIL] NTUST SSO login failed", file=sys.stderr)
            return 3
        client = ClassroomClient(bridge)

        if campus is None:
            campuses = client.campuses()
            if campuses is None:
                print("[FAIL] could not read campus list", file=sys.stderr)
                return 3
            print(json.dumps(campuses, ensure_ascii=False, indent=2))
            return 0

        usage = client.usage(campus, when, building)
        if usage is None:
            print("[FAIL] could not read the grid", file=sys.stderr)
            return 3
        print(json.dumps(usage, ensure_ascii=False))
    return 0


def _self_check() -> None:
    """Parsers are pure; exercise the shapes that actually differ."""
    assert day_argument(date(2000, 1, 1)) == "0"
    assert day_argument(date(2000, 1, 2)) == "1"
    assert day_argument(date(2026, 9, 15)) == str((datetime(2026, 9, 15, tzinfo=timezone.utc) - CALENDAR_EPOCH).days)

    # No grid at all -> None (failure), distinct from a grid with no rows.
    assert parse_grid("<html><body>login please</body></html>") is None

    cells = "".join(f"<td>c{i}</td>" for i in range(SECTION_COUNT))
    header = "<tr><th>room</th></tr>"
    row = f'<tr><td>T1-101</td>{cells}</tr>'
    pager = "<tr><td colspan='15'><a href=\"javascript:__doPostBack('showinfo_grd$_ctl54$_ctl1','')\">2</a></td></tr>"
    html = f"<table id='{GRID_ID}'>{header}{row}{pager}</table>"
    grid = parse_grid(html)
    assert grid is not None and len(grid) == 1, grid
    assert grid[0]["name"] == "T1-101"
    assert len(grid[0]["slots"]) == SECTION_COUNT

    # Weekend shape: grid present, no data rows -> [] not None.
    empty = parse_grid(f"<table id='{GRID_ID}'>{header}{pager}</table>")
    assert empty == [], empty

    # The pager target must be read, not assumed.
    assert parse_pager_target(html, 2) == ("showinfo_grd$_ctl54$_ctl1", "")
    assert parse_pager_target(html, 3) is None

    # The nested placeholder must not leak into the cell text, and its fixed
    # height/width must not read as a mark.
    plain = BeautifulSoup(
        "<td><table style='height:16px;width:80px'><tr><td></td></tr></table>"
        "\n\t\t表達與經典閱讀楊穎詩\n\t</td>",
        "html.parser",
    ).find("td")
    assert _parse_slot(plain) == {"text": "表達與經典閱讀楊穎詩", "marked": False}

    # An empty slot is empty text, not a missing slot.
    empty = BeautifulSoup(
        "<td><table style='height:16px;width:80px'><tr><td></td></tr></table></td>",
        "html.parser",
    ).find("td")
    assert _parse_slot(empty) == {"text": "", "marked": False}

    # A filled placeholder is the mark.
    filled = BeautifulSoup(
        "<td><table><tr><td bgcolor='#ff0'></td></tr></table>X</td>", "html.parser",
    ).find("td")
    assert _parse_slot(filled) == {"text": "X", "marked": True}

    # The login page is not an OIDC bridge.
    assert find_form_post_bridge(
        "<form action='/x'><input name='Username'><input name='Password'></form>"
    ) is None
    assert find_form_post_bridge(
        "<form action='/signin-oidc'><input name='code' value='C'>"
        "<input name='state' value='S'></form>"
    ) == ("/signin-oidc", {"code": "C", "state": "S"})

    # Unchecked boxes and submit buttons stay out of the payload.
    fields = form_fields(
        "<form><input name='__VIEWSTATE' value='V'>"
        "<input type='submit' name='btn' value='go'>"
        "<input type='checkbox' name='cb' value='1'>"
        "<select name='s'><option value='a'>A</option>"
        "<option value='b' selected>B</option></select></form>"
    )
    assert fields == {"__VIEWSTATE": "V", "s": "b"}, fields
    print("self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        sys.exit(0)
    sys.exit(main())
