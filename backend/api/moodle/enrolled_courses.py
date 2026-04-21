"""Moodle enrolled-courses probe via long-lived OIDC webservice token."""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

SITE_INFO_WSFUNCTION = "core_webservice_get_site_info"
COURSES_WSFUNCTION = "core_enrol_get_users_courses"


def fetch_enrolled_courses(client: MoodleOidcAuthClient) -> list:
    site_info = client.call(SITE_INFO_WSFUNCTION)
    userid = site_info["userid"]
    return client.call(COURSES_WSFUNCTION, userid=userid)


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        result = fetch_enrolled_courses(client)
        if isinstance(result, dict) and result.get("errorcode"):
            print(f"[FAIL] {result}", file=sys.stderr)
            return 3
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
