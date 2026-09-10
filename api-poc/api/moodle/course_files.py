"""Moodle course-files probe via long-lived OIDC webservice token.

core_course_get_contents returns the whole section/module tree; this flattens it
to the course material — uploaded files and mod_url links alike.

Only `type == "file"` rows are hosted on Moodle and need `?token=<wstoken>`
appended to fileurl (or `&token=` when it already has a query) before they can
be fetched. `type == "url"` rows are external links (Google Drive, YouTube, ...)
with no mimetype and filesize 0; open them as-is.
"""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

WSFUNCTION = "core_course_get_contents"
MATERIAL_TYPES = ("file", "url")


def fetch_course_contents(
    client: MoodleOidcAuthClient,
    course_id: int,
) -> list:
    return client.call(WSFUNCTION, courseid=course_id)


def flatten_files(sections: list) -> list[dict]:
    return [
        {
            "type": content.get("type"),
            "section": section.get("name"),
            "module": module.get("name"),
            "modname": module.get("modname"),
            "filename": content.get("filename"),
            "filesize": content.get("filesize"),
            "mimetype": content.get("mimetype"),
            "fileurl": content.get("fileurl"),
            "timemodified": content.get("timemodified"),
        }
        for section in sections
        for module in section.get("modules", [])
        for content in module.get("contents", [])
        if content.get("type") in MATERIAL_TYPES
    ]


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    if len(sys.argv) != 2:
        print("usage: python -m api.moodle.course_files <courseid>", file=sys.stderr)
        return 2
    try:
        course_id = int(sys.argv[1])
    except ValueError:
        print("course id must be an integer", file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        result = fetch_course_contents(client, course_id)
        if isinstance(result, dict) and result.get("errorcode"):
            print(f"[FAIL] {result}", file=sys.stderr)
            return 3
        print(json.dumps(flatten_files(result), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
