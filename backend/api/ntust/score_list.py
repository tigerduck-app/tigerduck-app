"""NTUST 选课系统：班级课表抓取 + 课号正则匹配."""

from __future__ import annotations

import json

from api import load_creds
from api.ntust import html_score_parser
from api.ntust.sso import DEFAULT_DB_PATH, NtustSsoBridge

SCORE_LIST_ROOT_URL = "https://stuinfosys.ntust.edu.tw/StuScoreQueryServ/"
SCORE_LIST_URL = (
    "https://stuinfosys.ntust.edu.tw/StuScoreQueryServ/StuScoreQuery/DisplayAll"
)


class NtustCourseSelectionClient:
    def __init__(
        self,
        student_id: str,
        password: str,
        db_path=DEFAULT_DB_PATH,
    ) -> None:
        self._bridge = NtustSsoBridge(student_id, password, db_path)
        self._logged_in = False

    def __enter__(self) -> "NtustCourseSelectionClient":
        return self

    def __exit__(self, *exc: object) -> None:
        self._bridge.close()

    def login(self) -> bool:
        if not self._logged_in:
            self._logged_in = self._bridge.ensure_service_login(
                SCORE_LIST_ROOT_URL,
            )
        return self._logged_in

    def get_score_list(self) -> str:
        if not self.login():
            raise RuntimeError("Login failed")
        resp = self._bridge.open(SCORE_LIST_URL)
        if "ssoam2.ntust.edu.tw" in str(resp.url):
            raise RuntimeError("Redirected back to SSO while fetching score list")
        return resp.text

    def cookie_dict(self) -> dict[str, str]:
        return self._bridge.cookie_dict()

    def cookie_detail(self) -> list[dict]:
        return self._bridge.cookie_detail()


if __name__ == "__main__":
    sid, pwd = load_creds()
    with NtustCourseSelectionClient(sid, pwd) as client:
        print("login =", client.login())
        print(
            json.dumps(
                html_score_parser.parse(client.get_score_list()),
                ensure_ascii=False,
                indent=2,
            )
        )
