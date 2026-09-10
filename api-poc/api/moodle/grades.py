"""Moodle grades probe via long-lived OIDC webservice token.

Per-course grade items for the logged-in user. Without a courseid it falls back
to gradereport_overview, which is one final grade per enrolled course.
"""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

SITE_INFO_WSFUNCTION = "core_webservice_get_site_info"
COURSE_WSFUNCTION = "gradereport_user_get_grade_items"
OVERVIEW_WSFUNCTION = "gradereport_overview_get_course_grades"


def fetch_course_grades(
    client: MoodleOidcAuthClient,
    course_id: int,
) -> dict:
    userid = client.call(SITE_INFO_WSFUNCTION)["userid"]
    return client.call(COURSE_WSFUNCTION, courseid=course_id, userid=userid)


def fetch_grade_overview(client: MoodleOidcAuthClient) -> dict:
    return client.call(OVERVIEW_WSFUNCTION)


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    if len(sys.argv) > 2:
        print("usage: python -m api.moodle.grades [courseid]", file=sys.stderr)
        return 2
    try:
        course_id = int(sys.argv[1]) if len(sys.argv) == 2 else None
    except ValueError:
        print("course id must be an integer", file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        result = (
            fetch_grade_overview(client)
            if course_id is None
            else fetch_course_grades(client, course_id)
        )
        if isinstance(result, dict) and result.get("errorcode"):
            print(f"[FAIL] {result}", file=sys.stderr)
            return 3
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
