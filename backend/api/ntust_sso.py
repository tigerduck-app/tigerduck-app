import logging
import os
import re
import sqlite3
import time
from pathlib import Path
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup
from httpx import Timeout

DEFAULT_DB_PATH = "ntust_cookies.sqlite3"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)
logging.getLogger("httpx").setLevel(logging.WARNING)


class SQLiteCookieStore:
    def __init__(self, db_path: str = DEFAULT_DB_PATH):
        self._db = sqlite3.connect(Path(db_path))
        self._db.row_factory = sqlite3.Row
        self._init_db()

    def _init_db(self) -> None:
        self._db.execute(
            """
            CREATE TABLE IF NOT EXISTS cookies (
                                                   account    TEXT NOT NULL,
                                                   name       TEXT NOT NULL,
                                                   value      TEXT NOT NULL,
                                                   domain     TEXT NOT NULL DEFAULT '',
                                                   path       TEXT NOT NULL DEFAULT '/',
                                                   expires    INTEGER,
                                                   secure     INTEGER NOT NULL DEFAULT 0,
                                                   httponly   INTEGER NOT NULL DEFAULT 0,
                                                   created_at INTEGER NOT NULL,
                                                   updated_at INTEGER NOT NULL,
                                                   PRIMARY KEY (account, name, domain, path)
                )
            """
        )
        self._db.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_cookies_account
                ON cookies(account)
            """
        )
        self._db.commit()

    def load_into(self, account: str, client: httpx.Client) -> bool:
        rows = self._db.execute(
            """
            SELECT name, value, domain, path
            FROM cookies
            WHERE account = ?
            ORDER BY domain, path, name
            """,
            (account,),
        ).fetchall()

        if not rows:
            return False

        client.cookies.clear()
        for row in rows:
            client.cookies.set(
                row["name"],
                row["value"],
                domain=row["domain"] or "",
                path=row["path"] or "/",
            )

        logger.info("Loaded %d cookies from sqlite for %s", len(rows), account)
        return True

    def save_from(self, account: str, client: httpx.Client) -> None:
        now = int(time.time())

        self._db.execute("DELETE FROM cookies WHERE account = ?", (account,))

        inserted = 0
        for cookie in client.cookies.jar:
            rest = getattr(cookie, "_rest", {}) or {}
            httponly = (
                1 if any(str(k).lower() == "httponly" for k in rest.keys()) else 0
            )

            self._db.execute(
                """
                INSERT INTO cookies (
                    account, name, value, domain, path,
                    expires, secure, httponly, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    account,
                    cookie.name,
                    cookie.value,
                    cookie.domain or "",
                    cookie.path or "/",
                    cookie.expires,
                    1 if cookie.secure else 0,
                    httponly,
                    now,
                    now,
                ),
            )
            inserted += 1

        self._db.commit()
        logger.info("Saved %d cookies into sqlite for %s", inserted, account)

    def delete(self, account: str) -> None:
        self._db.execute("DELETE FROM cookies WHERE account = ?", (account,))
        self._db.commit()
        logger.info("Deleted cached cookies for %s", account)

    def close(self) -> None:
        self._db.close()


class NtustSsoBridge:
    """
    NTUST SSO 登入跳板。
    只做必要流程：
    - 讀取 / 儲存 cookies
    - 判斷是否被導到 SSO 登入頁
    - 送出 SSO loginForm
    - 自動提交 OIDC bridge form
    """

    def __init__(self, student_id: str, password: str, db_path: str = DEFAULT_DB_PATH):
        self._account = student_id.strip().upper()
        self._password = password
        self._store = SQLiteCookieStore(db_path=db_path)
        self._is_authenticated = False

        self._client = httpx.Client(
            http2=True,
            follow_redirects=True,
            timeout=Timeout(15.0),
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/141.0.0.0 Safari/537.36"
                ),
                "Accept": (
                    "text/html,application/xhtml+xml,application/xml;q=0.9,"
                    "image/avif,image/webp,image/apng,*/*;q=0.8"
                ),
                "Accept-Language": "zh-TW,zh;q=0.9",
                "Upgrade-Insecure-Requests": "1",
            },
        )

    @property
    def client(self) -> httpx.Client:
        return self._client

    @staticmethod
    def _is_sso_login_page(response: httpx.Response) -> bool:
        if "ssoam2.ntust.edu.tw" not in str(response.url):
            return False

        soup = BeautifulSoup(response.text, "html.parser")
        if soup.find("form", id="loginForm"):
            return True

        input_names = {inp.get("name", "") for inp in soup.find_all("input")}
        return "Username" in input_names and "Password" in input_names

    @staticmethod
    def _build_form_payload(form) -> dict:
        payload = {}
        for input_tag in form.find_all("input"):
            name = input_tag.get("name")
            value = input_tag.get("value", "")
            if name:
                payload[name] = value
        return payload

    @staticmethod
    def _find_oidc_bridge_form(html: str):
        """
        只找真正的 OIDC / SSO bridge form。
        明確排除 Logout 這類表單。
        """
        soup = BeautifulSoup(html, "html.parser")

        for form in soup.find_all("form"):
            action = (form.get("action") or "").strip()
            if not action:
                continue

            action_lower = action.lower()
            if "logout" in action_lower:
                continue

            inputs = form.find_all("input")
            if not inputs:
                continue

            payload_names = {
                (inp.get("name") or "").strip() for inp in inputs if inp.get("name")
            }

            # 明確只接受常見 OIDC / SAML bridge 參數
            oidc_like = bool(
                {"code", "state", "iss"} <= payload_names
                or "id_token" in payload_names
                or "SAMLResponse" in payload_names
                or "RelayState" in payload_names
                or "wresult" in payload_names
                or "wctx" in payload_names
            )

            if not oidc_like:
                continue

            # 不接受有 Username / Password 這類互動登入欄位的 form
            if "Username" in payload_names or "Password" in payload_names:
                continue

            return form

        return None

    def _resolve_oidc_bridge_forms(
        self,
        response: httpx.Response,
        max_steps: int = 3,
    ) -> httpx.Response:
        current = response

        for _ in range(max_steps):
            if self._is_sso_login_page(current):
                return current

            form = self._find_oidc_bridge_form(current.text)
            if not form:
                return current

            action = urljoin(str(current.url), form.get("action"))
            payload = self._build_form_payload(form)

            logger.info(
                "Submitting OIDC bridge form: action=%s fields=%s",
                action,
                list(payload.keys()),
            )

            current = self._client.post(action, data=payload)
            current.raise_for_status()

        return current

    def _submit_sso_login_form(self, response: httpx.Response) -> httpx.Response:
        soup = BeautifulSoup(response.text, "html.parser")
        form = soup.find("form", id="loginForm")
        if not form:
            raise RuntimeError("SSO login form not found")

        payload = self._build_form_payload(form)
        payload["Username"] = self._account
        payload["Password"] = self._password
        payload.setdefault("captcha", "")

        action = urljoin(str(response.url), form.get("action") or str(response.url))

        resp = self._client.post(action, data=payload)
        resp.raise_for_status()
        return resp

    def _load_cached_cookies(self) -> bool:
        return self._store.load_into(self._account, self._client)

    def _save_cookies(self) -> None:
        self._store.save_from(self._account, self._client)

    def _clear_cached_cookies(self) -> None:
        self._client.cookies.clear()
        self._store.delete(self._account)

    def ensure_service_login(self, service_root_url: str) -> bool:
        """
        流程：
        1. 先載入 cookies
        2. 訪問 service root
        3. 若沒有落到 SSO login page，視為已登入
        4. 若落到 SSO login page，就重新登入
        """
        if self._is_authenticated:
            return True

        self._load_cached_cookies()

        try:
            resp = self._client.get(service_root_url)
            resp.raise_for_status()
            resp = self._resolve_oidc_bridge_forms(resp)

            if not self._is_sso_login_page(resp):
                logger.info("Already logged in for service root: %s", resp.url)
                self._save_cookies()
                self._is_authenticated = True
                return True

            logger.info("Redirected to SSO login page, performing fresh login.")
            self._clear_cached_cookies()

            resp = self._client.get(service_root_url)
            resp.raise_for_status()

            if not self._is_sso_login_page(resp):
                resp = self._resolve_oidc_bridge_forms(resp)
                self._save_cookies()
                self._is_authenticated = True
                return True

            resp = self._submit_sso_login_form(resp)
            resp = self._resolve_oidc_bridge_forms(resp)

            if self._is_sso_login_page(resp):
                return False

            self._save_cookies()
            self._is_authenticated = True
            logger.info("Login success. final_url=%s", resp.url)
            return True

        except Exception:
            logger.exception("ensure_service_login failed")
            return False

    def open(self, url: str) -> httpx.Response:
        resp = self._client.get(url)
        resp.raise_for_status()
        resp = self._resolve_oidc_bridge_forms(resp)
        self._save_cookies()
        return resp

    def cookie_dict(self) -> dict[str, str]:
        result = {}
        for cookie in self._client.cookies.jar:
            result[cookie.name] = cookie.value
        return result

    def cookie_detail(self) -> list[dict]:
        items = []
        for cookie in self._client.cookies.jar:
            items.append(
                {
                    "name": cookie.name,
                    "domain": cookie.domain,
                    "path": cookie.path,
                    "secure": cookie.secure,
                }
            )
        return items

    def close(self) -> None:
        try:
            self._client.close()
        finally:
            self._store.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()


if __name__ == "__main__":
    student_id = os.getenv("STUDENT_ID")
    password = os.getenv("PASSWORD")

    if not student_id or not password:
        raise RuntimeError("Missing STUDENT_ID or PASSWORD environment variables")

    with NtustSsoBridge(student_id, password) as bridge:
        bridge.open("https://ssoam2.ntust.edu.tw/")
        print(bridge.cookie_dict())
        print(bridge.cookie_detail())