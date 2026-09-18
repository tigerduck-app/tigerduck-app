"""Subsystem directory probe for i.ntust.edu.tw (campus service portal).

The portal renders every service the logged-in student can reach as grouped
link lists inside `#service`. Each group is a child element whose own id
contains "service"; `commonly-used-service` is a per-user shortcut block that
duplicates entries from the real groups, so it is skipped.

The page has a Chinese and an English variant at different paths. They are not
translations of one document — the English one is a separate page — so the
language must be chosen at fetch time, not by post-processing.

Failure mode worth separating: fetching the page but finding no `#service`
node means the server-side session expired or the portal was redesigned. That
is not "this student has no subsystems", and collapsing the two makes an
expired session look like an empty account.
"""

from __future__ import annotations

import json
import sys

from bs4 import BeautifulSoup

from api import load_creds
from api.ntust.sso import NtustSsoBridge

HOST = "https://i.ntust.edu.tw"
SUBSYSTEM_URL_ZH = f"{HOST}/student"
SUBSYSTEM_URL_EN = f"{HOST}/EN/student"

SERVICE_ROOT_ID = "service"
SHORTCUT_GROUP_ID = "commonly-used-service"


def parse_subsystems(html: str) -> list[dict[str, object]] | None:
    """Grouped service links, or None when `#service` is missing."""
    soup = BeautifulSoup(html, "html.parser")
    root = soup.find(id=SERVICE_ROOT_ID)
    if root is None:
        return None

    groups = []
    for group in root.find_all(recursive=False):
        group_id = group.get("id") or ""
        if SERVICE_ROOT_ID not in group_id:
            continue
        if group_id == SHORTCUT_GROUP_ID:
            continue
        links = [
            {
                "name": a.get_text(strip=True),
                "url": a.get("href", ""),
                "type": "link",
            }
            for a in group.find_all("a")
        ]
        groups.append({"id": group_id, "links": links})
    return groups


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    url = SUBSYSTEM_URL_EN if "--en" in sys.argv[1:] else SUBSYSTEM_URL_ZH

    with NtustSsoBridge(sid, pwd) as bridge:
        if not bridge.ensure_service_login(url):
            print("[FAIL] NTUST SSO login failed", file=sys.stderr)
            return 3
        resp = bridge.open(url)
        groups = parse_subsystems(resp.text)
        if groups is None:
            print(
                "[FAIL] #service node not found — session expired or page redesigned",
                file=sys.stderr,
            )
            return 3
        print(json.dumps({"url": url, "groups": groups}, ensure_ascii=False, indent=2))
    return 0


def _self_check() -> None:
    assert parse_subsystems("<html><body>login</body></html>") is None
    html = """
    <div id="service">
      <div id="commonly-used-service"><a href="/dup">Dup</a></div>
      <div id="academic-service"><a href="/a">A</a><a href="/b">B</a></div>
      <div id="not-a-group"><a href="/x">X</a></div>
    </div>
    """
    groups = parse_subsystems(html)
    assert groups == [
        {"id": "academic-service", "links": [
            {"name": "A", "url": "/a", "type": "link"},
            {"name": "B", "url": "/b", "type": "link"},
        ]}
    ], groups
    # An empty portal is [] — distinct from the None above.
    assert parse_subsystems('<div id="service"></div>') == []
    print("self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        sys.exit(0)
    sys.exit(main())
