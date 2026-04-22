"""Moodle homework fetcher via long-lived OIDC webservice token.

Replaces the SSO + sesskey + /lib/ajax/service.php scraping path
(kept in api/moodle/legacy/homework_sso.py for comparison) with
/webservice/rest/server.php using a Moodle Mobile App token.
"""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

WSFUNCTION = "core_calendar_get_action_events_by_timesort"
DEFAULT_TIMESORT_FROM = 1772899200  # 2026-03-05 00:00:00 UTC
DEFAULT_LIMIT = 50


def fetch_action_events(
    client: MoodleOidcAuthClient,
    *,
    timesort_from: int = DEFAULT_TIMESORT_FROM,
    limit: int = DEFAULT_LIMIT,
) -> dict:
    return client.call(
        WSFUNCTION,
        limitnum=limit,
        timesortfrom=timesort_from,
        limittononsuspendedevents=1,
    )


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        events = fetch_action_events(client)
        if isinstance(events, dict) and events.get("errorcode"):
            print(f"[FAIL] {events}", file=sys.stderr)
            return 3
        print(json.dumps(events, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
