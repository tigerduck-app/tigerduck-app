"""Moodle course-members probe via long-lived OIDC webservice token.

Lists every enrolled user of a course (classmates + teachers) with their roles.
"""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

WSFUNCTION = "core_enrol_get_enrolled_users"


def fetch_enrolled_users(
    client: MoodleOidcAuthClient,
    course_id: int,
) -> list:
    return client.call(WSFUNCTION, courseid=course_id)


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    if len(sys.argv) != 2:
        print("usage: python -m api.moodle.enrolled_users <courseid>", file=sys.stderr)
        return 2
    try:
        course_id = int(sys.argv[1])
    except ValueError:
        print("course id must be an integer", file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        result = fetch_enrolled_users(client, course_id)
        if isinstance(result, dict) and result.get("errorcode"):
            print(f"[FAIL] {result}", file=sys.stderr)
            return 3
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
