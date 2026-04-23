"""Legacy Moodle homework fetcher via NTUST SSO cookies + sesskey.

Kept for A/B comparison against the newer OIDC token flow in
api/moodle/homework.py. Not recommended for new code — this path
depends on HTML scraping of sesskey and the internal /lib/ajax/service.php
endpoint, both of which are brittle across Moodle upgrades.
"""

from __future__ import annotations

import json
import re
import sys

from api import load_creds
from api.ntust.sso import NtustSsoBridge

MOODLE_LOGIN_URL = "https://moodle2.ntust.edu.tw/login/index.php"
AJAX_URL_TMPL = (
    "https://moodle2.ntust.edu.tw/lib/ajax/service.php"
    "?sesskey={sesskey}&info=core_calendar_get_action_events_by_timesort"
)
AJAX_PAYLOAD = [
    {
        "index": 0,
        "methodname": "core_calendar_get_action_events_by_timesort",
        "args": {
            "limitnum": 50,
            "timesortfrom": 1772899200,
            "limittononsuspendedevents": True,
        },
    },
]
SESSKEY_PATTERN = re.compile(r'"sesskey":"([^"]+)"')


def fetch() -> dict:
    sid, pwd = load_creds()
    with NtustSsoBridge(sid, pwd) as bridge:
        if not bridge.ensure_service_login(MOODLE_LOGIN_URL):
            raise RuntimeError("SSO login failed")
        match = SESSKEY_PATTERN.search(bridge.open(MOODLE_LOGIN_URL).text)
        if not match:
            raise RuntimeError("Failed to extract sesskey")
        resp = bridge.client.post(
            AJAX_URL_TMPL.format(sesskey=match.group(1)),
            json=AJAX_PAYLOAD,
            headers={"Content-Type": "application/json"},
        )
        resp.raise_for_status()
        return resp.json()


def main() -> int:
    try:
        print(json.dumps(fetch(), ensure_ascii=False))
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
