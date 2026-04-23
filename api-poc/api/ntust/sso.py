"""NTUST SSO 登入跳板：cookie-based login via ssoam2.ntust.edu.tw."""

from __future__ import annotations

import logging
import sqlite3
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup

from api import RUNTIME_DIR, load_creds

DEFAULT_DB_PATH = RUNTIME_DIR / "ntust_cookies.sqlite3"

BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
)

# OIDC / SAML bridge-form signatures (any subset means it's a bridge form).
OIDC_MARKERS: tuple[frozenset[str], ...] = (
    frozenset({"code", "state", "iss"}),
    frozenset({"id_token"}),
    frozenset({"SAMLResponse"}),
    frozenset({"RelayState"}),
    frozenset({"wresult"}),
    frozenset({"wctx"}),
)

logger = logging.getLogger(__name__)
logging.getLogger("httpx").setLevel(logging.WARNING)


# ---------------- HTML helpers ----------------

def _form_payload(form) -> dict[str, str]:
    return {
        i.get("name"): i.get("value", "")
        for i in form.find_all("input") if i.get("name")
    }


def _is_login_page(resp: httpx.Response) -> bool:
    if "ssoam2.ntust.edu.tw" not in str(resp.url):
        return False
    soup = BeautifulSoup(resp.text, "html.parser")
    if soup.find("form", id="loginForm"):
        return True
    names = {i.get("name", "") for i in soup.find_all("input")}
    return "Username" in names and "Password" in names


def _find_bridge_form(html: str):
    soup = BeautifulSoup(html, "html.parser")
    for form in soup.find_all("form"):
        action = (form.get("action") or "").strip().lower()
        if not action or "logout" in action:
            continue
        names = {(i.get("name") or "").strip() for i in form.find_all("input")}
        if not names or {"Username", "Password"} & names:
            continue
        if any(marker <= names for marker in OIDC_MARKERS):
            return form
    return None


# ---------------- Persistence ----------------

class SQLiteCookieStore:
    """Minimal per-account cookie persistence (name/value/domain/path only)."""

    def __init__(self, db_path: str | Path = DEFAULT_DB_PATH) -> None:
        self._db = sqlite3.connect(Path(db_path))
        self._db.row_factory = sqlite3.Row
        self._db.executescript(
            """
            CREATE TABLE IF NOT EXISTS cookies (
                account TEXT NOT NULL,
                name    TEXT NOT NULL,
                value   TEXT NOT NULL,
                domain  TEXT NOT NULL DEFAULT '',
                path    TEXT NOT NULL DEFAULT '/',
                PRIMARY KEY (account, name, domain, path)
            );
            CREATE INDEX IF NOT EXISTS idx_cookies_account ON cookies(account);
            """
        )
        self._db.commit()

    def load_into(self, account: str, client: httpx.Client) -> bool:
        rows = self._db.execute(
            "SELECT name, value, domain, path FROM cookies WHERE account = ?",
            (account,),
        ).fetchall()
        if not rows:
            return False
        client.cookies.clear()
        for r in rows:
            client.cookies.set(
                r["name"], r["value"], domain=r["domain"], path=r["path"],
            )
        logger.info("Loaded %d cookies for %s", len(rows), account)
        return True

    def save_from(self, account: str, client: httpx.Client) -> None:
        self._db.execute("DELETE FROM cookies WHERE account = ?", (account,))
        data = [
            (account, c.name, c.value, c.domain or "", c.path or "/")
            for c in client.cookies.jar
        ]
        self._db.executemany(
            "INSERT INTO cookies (account, name, value, domain, path) VALUES (?,?,?,?,?)",
            data,
        )
        self._db.commit()
        logger.info("Saved %d cookies for %s", len(data), account)

    def delete(self, account: str) -> None:
        self._db.execute("DELETE FROM cookies WHERE account = ?", (account,))
        self._db.commit()
        logger.info("Deleted cookies for %s", account)

    def close(self) -> None:
        self._db.close()


# ---------------- Bridge ----------------

class NtustSsoBridge:
    """NTUST SSO bridge: cookie-based login via ssoam2, OIDC/SAML pass-through."""

    def __init__(
        self,
        student_id: str,
        password: str,
        db_path: str | Path = DEFAULT_DB_PATH,
    ) -> None:
        self._account = student_id.strip().upper()
        self._password = password
        self._store = SQLiteCookieStore(db_path)
        self._is_authenticated = False
        self._client = httpx.Client(
            http2=True,
            follow_redirects=True,
            timeout=15.0,
            headers={
                "User-Agent": BROWSER_UA,
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

    def __enter__(self) -> "NtustSsoBridge":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # ---- public ----

    def ensure_service_login(self, service_root_url: str) -> bool:
        if self._is_authenticated:
            return True
        self._store.load_into(self._account, self._client)
        try:
            resp = self._resolve_bridges(self._client.get(service_root_url))
            if _is_login_page(resp):
                logger.info("Cached cookies invalid; performing fresh SSO login.")
                self._clear_cookies()
                resp = self._client.get(service_root_url)
                if _is_login_page(resp):
                    resp = self._submit_login_form(resp)
                resp = self._resolve_bridges(resp)
                if _is_login_page(resp):
                    return False
            return self._finalize(resp)
        except Exception:
            logger.exception("ensure_service_login failed")
            return False

    def open(self, url: str) -> httpx.Response:
        resp = self._resolve_bridges(self._client.get(url))
        resp.raise_for_status()
        self._store.save_from(self._account, self._client)
        return resp

    def cookie_dict(self) -> dict[str, str]:
        return {c.name: c.value for c in self._client.cookies.jar}

    def cookie_detail(self) -> list[dict[str, Any]]:
        return [
            {"name": c.name, "domain": c.domain, "path": c.path, "secure": c.secure}
            for c in self._client.cookies.jar
        ]

    def close(self) -> None:
        try:
            self._client.close()
        finally:
            self._store.close()

    # ---- internal ----

    def _clear_cookies(self) -> None:
        self._client.cookies.clear()
        self._store.delete(self._account)

    def _finalize(self, resp: httpx.Response) -> bool:
        self._store.save_from(self._account, self._client)
        self._is_authenticated = True
        logger.info("Login success. final_url=%s", resp.url)
        return True

    def _resolve_bridges(
        self,
        resp: httpx.Response,
        max_steps: int = 3,
    ) -> httpx.Response:
        current = resp
        current.raise_for_status()
        for _ in range(max_steps):
            if _is_login_page(current):
                return current
            form = _find_bridge_form(current.text)
            if not form:
                return current
            action = urljoin(str(current.url), form.get("action"))
            payload = _form_payload(form)
            logger.info("OIDC bridge: action=%s fields=%s", action, list(payload))
            current = self._client.post(action, data=payload)
            current.raise_for_status()
        return current

    def _submit_login_form(self, resp: httpx.Response) -> httpx.Response:
        soup = BeautifulSoup(resp.text, "html.parser")
        form = soup.find("form", id="loginForm")
        if not form:
            raise RuntimeError("SSO login form not found")
        payload = _form_payload(form)
        payload.update(Username=self._account, Password=self._password)
        payload.setdefault("captcha", "")
        action = urljoin(str(resp.url), form.get("action") or str(resp.url))
        out = self._client.post(action, data=payload)
        out.raise_for_status()
        return out


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )
    sid, pwd = load_creds()
    with NtustSsoBridge(sid, pwd) as bridge:
        bridge.open("https://ssoam2.ntust.edu.tw/")
        print(bridge.cookie_dict())
        print(bridge.cookie_detail())
