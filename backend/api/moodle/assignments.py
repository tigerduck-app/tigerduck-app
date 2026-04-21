"""Moodle assignments probe via long-lived OIDC webservice token."""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

WSFUNCTION = "mod_assign_get_assignments"


def fetch_assignments(
    client: MoodleOidcAuthClient,
    course_ids: list[int] | None = None,
) -> dict:
    args: dict[str, int] = {}
    if course_ids is not None:
        for idx, course_id in enumerate(course_ids):
            args[f"courseids[{idx}]"] = course_id
    return client.call(WSFUNCTION, **args)


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    try:
        course_ids = [int(arg) for arg in sys.argv[1:]]
    except ValueError:
        print("course ids must be integers", file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        result = fetch_assignments(client, course_ids or None)
        if isinstance(result, dict) and result.get("errorcode"):
            print(f"[FAIL] {result}", file=sys.stderr)
            return 3
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
