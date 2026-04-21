"""Moodle submission-status probe via long-lived OIDC webservice token."""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

SITE_INFO_WSFUNCTION = "core_webservice_get_site_info"
ASSIGNMENTS_WSFUNCTION = "mod_assign_get_assignments"
WSFUNCTION = "mod_assign_get_submission_status"


def fetch_submission_status(
    client: MoodleOidcAuthClient,
    assignid: int,
    userid: int,
) -> dict:
    return client.call(WSFUNCTION, assignid=assignid, userid=userid)


def resolve_first_assignment_id(client: MoodleOidcAuthClient) -> int:
    assignments = client.call(ASSIGNMENTS_WSFUNCTION)
    for course in assignments.get("courses", []):
        for assignment in course.get("assignments", []):
            return int(assignment["id"])
    raise RuntimeError("No assignments available")


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    assignid = int(sys.argv[1]) if len(sys.argv) > 1 else None

    with MoodleOidcAuthClient(sid, pwd) as client:
        site_info = client.call(SITE_INFO_WSFUNCTION)
        userid = site_info["userid"]
        if assignid is None:
            try:
                assignid = resolve_first_assignment_id(client)
            except RuntimeError as e:
                print(e, file=sys.stderr)
                return 3

        result = fetch_submission_status(client, assignid=assignid, userid=userid)
        if isinstance(result, dict) and result.get("errorcode"):
            print(f"[FAIL] {result}", file=sys.stderr)
            return 3
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
