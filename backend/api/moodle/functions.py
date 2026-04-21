"""Moodle site-info probe via long-lived OIDC webservice token.

Calls core_webservice_get_site_info via /webservice/rest/server.php
using a Moodle Mobile App token.
"""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

WSFUNCTION = "core_webservice_get_site_info"


def fetch_site_info(
    client: MoodleOidcAuthClient,
) -> dict:
    return client.call(
        WSFUNCTION,
    )


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        events = fetch_site_info(client)
        if isinstance(events, dict) and events.get("errorcode"):
            print(f"[FAIL] {events}", file=sys.stderr)
            return 3
        print(json.dumps(events, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
