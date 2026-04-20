"""Enrich each enrolled course number with detail via ntust-courses pypi pkg."""

from __future__ import annotations

from ntust_courses import search_courses

from api import load_creds
from api.ntust.course_list import COURSE_NO_PATTERN, NtustCourseSelectionClient

SEMESTER = "1142"


def main() -> int:
    sid, pwd = load_creds()
    with NtustCourseSelectionClient(sid, pwd) as client:
        if not client.login():
            raise SystemExit("Login failed")
        courses = COURSE_NO_PATTERN.findall(client.get_class_table())
        print(courses)
        for course_no in courses:
            print(search_courses(semester=SEMESTER, course_no=course_no))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
