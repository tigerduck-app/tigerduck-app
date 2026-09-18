"""Moodle notification-centre probe via long-lived OIDC webservice token.

Four read endpoints back a notification centre:

* `message_popup_get_popup_notifications` — the list itself, paginated.
* `message_popup_get_unread_popup_notification_count` — popup unread badge.
* `core_message_get_unread_notification_count` — @since Moodle 4.0, counts
  every notification rather than only the popup ones. Pick whichever the
  site's `site_info.functions[]` actually advertises; older sites have only
  the popup one, and calling a missing function returns `accessexception`.
* `core_message_get_user_notification_preferences` — the per-provider
  notification matrix (takes no arguments).

Two server behaviours worth knowing before wiring a client:

* `useridto` must be a real user id. Neither counter has the usual
  "0 means the current user" fallback, so passing 0 returns accessdenied.
* `limit` defaults to 0 on the server, which means *unbounded*. Always send
  an explicit limit or a busy account will drag the whole inbox down in one
  response.
"""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

SITE_INFO_WSFUNCTION = "core_webservice_get_site_info"
LIST_WSFUNCTION = "message_popup_get_popup_notifications"
POPUP_COUNT_WSFUNCTION = "message_popup_get_unread_popup_notification_count"
TOTAL_COUNT_WSFUNCTION = "core_message_get_unread_notification_count"
PREFERENCES_WSFUNCTION = "core_message_get_user_notification_preferences"

PAGE_LIMIT = 50
MAX_PAGES = 4


def _is_error(payload: object) -> bool:
    return isinstance(payload, dict) and bool(payload.get("errorcode"))


def preferred_count_wsfunction(site_info: dict) -> str | None:
    """Pick the unread counter this site advertises, or None if neither."""
    available = {f.get("name") for f in site_info.get("functions", [])}
    if not available:
        # Site did not enumerate its functions; the popup one is the older and
        # more widely present of the two, so it is the safer blind guess.
        return POPUP_COUNT_WSFUNCTION
    for name in (POPUP_COUNT_WSFUNCTION, TOTAL_COUNT_WSFUNCTION):
        if name in available:
            return name
    return None


def fetch_notifications(client: MoodleOidcAuthClient, user_id: int) -> list:
    """Walk the popup notification list until a short page or the page cap."""
    out: list = []
    for page in range(MAX_PAGES):
        result = client.call(
            LIST_WSFUNCTION,
            useridto=user_id,
            newestfirst=1,
            limit=PAGE_LIMIT,
            offset=page * PAGE_LIMIT,
        )
        if _is_error(result):
            return result
        batch = result.get("notifications", [])
        out.extend(batch)
        if len(batch) < PAGE_LIMIT:
            break
    return out


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        site_info = client.call(SITE_INFO_WSFUNCTION)
        if _is_error(site_info):
            print(f"[FAIL] {site_info}", file=sys.stderr)
            return 3
        user_id = site_info["userid"]

        report: dict[str, object] = {"userid": user_id}

        count_fn = preferred_count_wsfunction(site_info)
        report["count_wsfunction"] = count_fn
        if count_fn:
            report["unread"] = client.call(count_fn, useridto=user_id)

        notifications = fetch_notifications(client, user_id)
        if _is_error(notifications):
            print(f"[FAIL] {notifications}", file=sys.stderr)
            return 3
        report["notifications"] = notifications

        report["preferences"] = client.call(PREFERENCES_WSFUNCTION)

        print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
