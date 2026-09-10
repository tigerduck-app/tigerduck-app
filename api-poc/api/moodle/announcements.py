"""Moodle announcements probe via long-lived OIDC webservice token.

Announcements live in the course's `news` forum, so this is two calls:
list the forums of a course, then pull the discussions of the news one.
"""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

FORUMS_WSFUNCTION = "mod_forum_get_forums_by_courses"
DISCUSSIONS_WSFUNCTION = "mod_forum_get_forum_discussions"
NEWS_FORUM_TYPE = "news"


def fetch_announcements(
    client: MoodleOidcAuthClient,
    course_id: int,
) -> list:
    forums = client.call(FORUMS_WSFUNCTION, **{"courseids[0]": course_id})
    if isinstance(forums, dict) and forums.get("errorcode"):
        return forums
    out = []
    for forum in forums:
        if forum.get("type") != NEWS_FORUM_TYPE:
            continue
        discussions = client.call(DISCUSSIONS_WSFUNCTION, forumid=forum["id"])
        if isinstance(discussions, dict) and discussions.get("errorcode"):
            return discussions
        out.extend(discussions.get("discussions", []))
    return out


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    if len(sys.argv) != 2:
        print("usage: python -m api.moodle.announcements <courseid>", file=sys.stderr)
        return 2
    try:
        course_id = int(sys.argv[1])
    except ValueError:
        print("course id must be an integer", file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        result = fetch_announcements(client, course_id)
        if isinstance(result, dict) and result.get("errorcode"):
            print(f"[FAIL] {result}", file=sys.stderr)
            return 3
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
