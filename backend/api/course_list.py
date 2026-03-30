import os
import re

from ntust_sso import NtustSsoBridge

COURSE_SELECTION_ROOT_URL = "https://courseselection.ntust.edu.tw/"
COURSE_LIST_URL = "https://courseselection.ntust.edu.tw/ChooseList/D01/D01"


class NtustCourseSelectionClient:
    def __init__(
        self, student_id: str, password: str, db_path: str = "ntust_cookies.sqlite3"
    ):
        self._bridge = NtustSsoBridge(
            student_id=student_id,
            password=password,
            db_path=db_path,
        )
        self._logged_in = False

    def login(self) -> bool:
        if self._logged_in:
            return True

        ok = self._bridge.ensure_service_login(COURSE_SELECTION_ROOT_URL)
        self._logged_in = ok
        return ok

    def get_class_table(self) -> str:
        if not self.login():
            raise RuntimeError("Login failed")

        resp = self._bridge.open(COURSE_LIST_URL)

        if "ssoam2.ntust.edu.tw" in str(resp.url):
            raise RuntimeError(
                "Redirected back to SSO login page while fetching class table."
            )

        return resp.text

    def cookie_dict(self) -> dict[str, str]:
        return self._bridge.cookie_dict()

    def cookie_detail(self) -> list[dict]:
        return self._bridge.cookie_detail()

    def close(self) -> None:
        self._bridge.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()


if __name__ == "__main__":
    student_id = os.getenv("STUDENT_ID")
    password = os.getenv("PASSWORD")

    if not student_id or not password:
        raise RuntimeError("Missing STUDENT_ID or PASSWORD environment variables")

    with NtustCourseSelectionClient(student_id, password) as client:
        ok = client.login()
        print("login =", ok)
        print("cookie_dict =", client.cookie_dict())
        print("cookie_detail =", client.cookie_detail())
        print("\n\n\n\n\n")
        if ok:
            html = client.get_class_table()
            result = re.findall(r"<tr>\s*<td>\s*(3?[A-Z][A-Z][A-Z0-9]{6,7})\s*</td>", html)
            print(result)
            # ['CS1007701', 'CS2001301', 'CS2006301', 'CS2008301', 'CS3001302', 'CS3019701', 'EC1013701', 'EC1014701', 'PE139B022']
