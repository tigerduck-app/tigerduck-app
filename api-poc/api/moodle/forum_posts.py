"""Moodle forum thread probe via long-lived OIDC webservice token.

Reads that a forum reader/editor needs beyond the discussion list:

* `mod_forum_get_discussion_posts` — every post in one discussion.
* `mod_forum_get_discussion_post` — a single post, fetched in the shape an
  editor needs.
* `mod_forum_get_forum_access_information` — the capability snapshot for one
  forum. The response is `load_capability_def('mod_forum')` flattened at
  runtime, so the field set tracks the site version and every field is
  VALUE_OPTIONAL. Notably there is no `caneditownpost`.

The `moodlewssetting*` flags are the subtle part, and they differ per call:

* Reading a thread for *display* wants `filter=true` and `fileurl=true`, so
  media filters run and `@@PLUGINFILE@@` is resolved to fetchable URLs.
* Reading a post for *editing* wants the opposite: `raw=true`, `filter=false`,
  `fileurl=false`. Rendered output sent back to the server is permanent
  corruption — filter output gets frozen into the stored text and the
  `@@PLUGINFILE@@` placeholders are replaced by absolute URLs that break as
  soon as the file is moved. When the exporter happens not to run
  `format_text` these three flags are a no-op, so setting them is correct
  either way.
"""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

POSTS_WSFUNCTION = "mod_forum_get_discussion_posts"
POST_WSFUNCTION = "mod_forum_get_discussion_post"
ACCESS_WSFUNCTION = "mod_forum_get_forum_access_information"


def _is_error(payload: object) -> bool:
    return isinstance(payload, dict) and bool(payload.get("errorcode"))


def fetch_posts(client: MoodleOidcAuthClient, discussion_id: int) -> object:
    """Thread contents in display shape."""
    return client.call(
        POSTS_WSFUNCTION,
        discussionid=discussion_id,
        sortby="created",
        sortdirection="ASC",
        includeinlineattachments=1,
        moodlewssettingfilter="true",
        moodlewssettingfileurl="true",
    )


def fetch_post_for_edit(client: MoodleOidcAuthClient, post_id: int) -> object:
    """One post in edit shape — stored text, not rendered output."""
    return client.call(
        POST_WSFUNCTION,
        postid=post_id,
        moodlewssettingraw="true",
        moodlewssettingfilter="false",
        moodlewssettingfileurl="false",
    )


def fetch_access(client: MoodleOidcAuthClient, forum_id: int) -> object:
    return client.call(ACCESS_WSFUNCTION, forumid=forum_id)


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    if len(sys.argv) not in (2, 3):
        print(
            "usage: python -m api.moodle.forum_posts <discussionid> [forumid]",
            file=sys.stderr,
        )
        return 2
    try:
        discussion_id = int(sys.argv[1])
        forum_id = int(sys.argv[2]) if len(sys.argv) == 3 else None
    except ValueError:
        print("ids must be integers", file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        posts = fetch_posts(client, discussion_id)
        if _is_error(posts):
            print(f"[FAIL] {posts}", file=sys.stderr)
            return 3

        out: dict[str, object] = {"posts": posts}
        if forum_id is not None:
            out["access"] = fetch_access(client, forum_id)

        # Round-trip the first post through the edit-shaped read so the two
        # representations can be diffed side by side.
        entries = posts.get("posts", []) if isinstance(posts, dict) else []
        if entries:
            out["first_post_for_edit"] = fetch_post_for_edit(
                client, entries[0]["id"],
            )
        print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
