"""Moodle quiz probe via long-lived OIDC webservice token.

Three reads, in the order a client needs them:

* `mod_quiz_get_quizzes_by_courses` — the quizzes of a course.
* `mod_quiz_get_user_attempts` — this user's attempts at one quiz.
  Moodle 5.0 renamed it to `mod_quiz_get_user_quiz_attempts`; the old name is
  deprecated in 5.0 and removed in 6.0, so pick whichever the site advertises.
* `mod_quiz_get_user_best_grade` — the best grade for one quiz.

Two arguments carry more weight than they look:

* `status` must be sent as `all`. The server defaults to `finished`, which
  silently drops the in-progress and overdue attempts — exactly the ones a
  student opens the app to look at.
* `userid` is deliberately *not* sent to the attempt endpoints. Both fall back
  to `$USER->id` when it is empty, and sending 0 is not the same thing.
"""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

SITE_INFO_WSFUNCTION = "core_webservice_get_site_info"
QUIZZES_WSFUNCTION = "mod_quiz_get_quizzes_by_courses"
ATTEMPTS_WSFUNCTION = "mod_quiz_get_user_attempts"
ATTEMPTS_WSFUNCTION_50 = "mod_quiz_get_user_quiz_attempts"
BEST_GRADE_WSFUNCTION = "mod_quiz_get_user_best_grade"

ATTEMPT_STATUS = "all"


def _is_error(payload: object) -> bool:
    return isinstance(payload, dict) and bool(payload.get("errorcode"))


def preferred_attempts_wsfunction(site_info: dict) -> str:
    """Prefer the Moodle 5.0 name when the site lists it."""
    available = {f.get("name") for f in site_info.get("functions", [])}
    if ATTEMPTS_WSFUNCTION_50 in available:
        return ATTEMPTS_WSFUNCTION_50
    return ATTEMPTS_WSFUNCTION


def fetch_quizzes(client: MoodleOidcAuthClient, course_id: int) -> object:
    return client.call(
        QUIZZES_WSFUNCTION,
        **{
            "courseids[0]": course_id,
            "moodlewssettingfilter": "true",
            "moodlewssettingfileurl": "true",
        },
    )


def fetch_attempts(
    client: MoodleOidcAuthClient,
    wsfunction: str,
    quiz_id: int,
) -> object:
    return client.call(
        wsfunction, quizid=quiz_id, status=ATTEMPT_STATUS, includepreviews=0,
    )


def fetch_best_grade(client: MoodleOidcAuthClient, quiz_id: int) -> object:
    return client.call(BEST_GRADE_WSFUNCTION, quizid=quiz_id)


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    if len(sys.argv) != 2:
        print("usage: python -m api.moodle.quizzes <courseid>", file=sys.stderr)
        return 2
    try:
        course_id = int(sys.argv[1])
    except ValueError:
        print("course id must be an integer", file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        site_info = client.call(SITE_INFO_WSFUNCTION)
        if _is_error(site_info):
            print(f"[FAIL] {site_info}", file=sys.stderr)
            return 3
        attempts_fn = preferred_attempts_wsfunction(site_info)

        quizzes = fetch_quizzes(client, course_id)
        if _is_error(quizzes):
            print(f"[FAIL] {quizzes}", file=sys.stderr)
            return 3

        out = {"attempts_wsfunction": attempts_fn, "quizzes": []}
        for quiz in quizzes.get("quizzes", []):
            quiz_id = quiz["id"]
            out["quizzes"].append({
                "id": quiz_id,
                "name": quiz.get("name"),
                "attempts": fetch_attempts(client, attempts_fn, quiz_id),
                "bestgrade": fetch_best_grade(client, quiz_id),
            })
        print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
