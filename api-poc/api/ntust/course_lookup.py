"""Enrich each enrolled course number with detail via ntust-courses pypi pkg."""

from __future__ import annotations

import sys
from datetime import date, datetime
from zoneinfo import ZoneInfo

from ntust_courses import search_courses

from api import load_creds
from api.ntust.course_list import COURSE_NO_PATTERN, NtustCourseSelectionClient


def current_semester(today: date) -> str:
    """The app's month guess (CourseSelectionService.heuristicSemesterCode): Feb-Jul is spring."""
    roc = today.year - 1911
    if 2 <= today.month <= 7:
        return f"{roc - 1}2"
    return f"{roc if today.month >= 8 else roc - 1}1"


def _self_check() -> None:
    assert current_semester(date(2026, 8, 1)) == "1151"
    assert current_semester(date(2026, 10, 16)) == "1151"
    assert current_semester(date(2027, 1, 31)) == "1151"
    assert current_semester(date(2027, 2, 1)) == "1152"
    assert current_semester(date(2027, 7, 31)) == "1152"
    print("self-check OK")


def main() -> int:
    # A term the school opens early is missed by the guess, so it can be named.
    semester = sys.argv[1] if len(sys.argv) > 1 else current_semester(
        datetime.now(ZoneInfo("Asia/Taipei")).date()
    )
    sid, pwd = load_creds()
    with NtustCourseSelectionClient(sid, pwd) as client:
        if not client.login():
            raise SystemExit("Login failed")
        courses = COURSE_NO_PATTERN.findall(client.get_class_table())
        print(courses)
        for course_no in courses:
            print(search_courses(semester=semester, course_no=course_no))
    return 0


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        raise SystemExit(0)
    raise SystemExit(main())
