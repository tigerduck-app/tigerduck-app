"""Moodle Mobile App OIDC login flow for NTUST moodle2.ntust.edu.tw.

Verified against real Moodle iOS App HAR dump (2026-04-21).
DO NOT POST /login/token.php — NTUST is OIDC-only; that path triggers
login_lockout and bans the account. Always use this launch.php flow.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import random
import re
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup

from api import RUNTIME_DIR, load_creds

SITE_URL = "https://moodle2.ntust.edu.tw"
SSO_URL = "https://ssoam2.ntust.edu.tw"
SERVICE = "moodle_mobile_app"
URL_SCHEME = "moodlemobile"
MOBILE_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
    "MoodleMobile 5.1.1 (51100)"
)
TOKEN_FILE = RUNTIME_DIR / "moodle_tokens.json"

logger = logging.getLogger(__name__)


class MoodleOidcAuthError(RuntimeError):
    pass


# ---------------- HTML parsers ----------------

def _parse_login_form(html: str) -> dict[str, str]:
    soup = BeautifulSoup(html, "html.parser")
    form = next(
        (
            f for f in soup.find_all("form")
            if {"Username", "Password"} <= {i.get("name") for i in f.find_all("input")}
        ),
        None,
    )
    if not form:
        raise MoodleOidcAuthError("SSO login form not found")
    fields = {i.get("name", ""): i.get("value", "") for i in form.find_all("input")}
    return {
        "action": form.get("action") or "/",
        "antiforgery": fields.get("__RequestVerificationToken", ""),
        "client_id": fields.get("ClientId", ""),
        "return_url": fields.get("ReturnUrl", ""),
        "uri": fields.get("Uri", ""),
    }


def _parse_oidc_form_post(html: str) -> dict[str, Any] | None:
    soup = BeautifulSoup(html, "html.parser")
    for form in soup.find_all("form"):
        action = (form.get("action") or "").strip()
        if "moodle2.ntust.edu.tw/auth/oidc" not in action:
            continue
        fields = {
            i.get("name"): i.get("value", "")
            for i in form.find_all("input") if i.get("name")
        }
        if {"code", "state", "iss"} <= set(fields):
            return {"action": action, "payload": fields}
    return None


def _extract_login_error(html: str) -> str | None:
    soup = BeautifulSoup(html, "html.parser")
    for cls in ("field-validation-error", "validation-summary-errors",
                "alert-danger", "text-danger"):
        el = soup.find(class_=cls)
        if el and (text := el.get_text(" ", strip=True)):
            return text
    return None


# ---------------- Client ----------------

class MoodleOidcAuthClient:
    """Long-lived Moodle Mobile App token via NTUST OIDC SSO."""

    def __init__(
        self,
        student_id: str,
        password: str,
        token_file: str | Path = TOKEN_FILE,
    ) -> None:
        self._account = student_id.strip().upper()
        self._password = password
        self._token_path = Path(token_file)
        self._client = httpx.Client(
            follow_redirects=True,
            timeout=20.0,
            headers={
                "User-Agent": MOBILE_UA,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7",
            },
        )

    def __enter__(self) -> "MoodleOidcAuthClient":
        return self

    def __exit__(self, *exc: object) -> None:
        self._client.close()

    # ---- public ----

    def get_token(self, force_refresh: bool = False) -> dict[str, Any]:
        if not force_refresh:
            if cached := self._read().get(self._account):
                return cached
        token = self._login()
        store = self._read()
        store[self._account] = token
        self._write(store)
        return token

    def invalidate(self) -> None:
        store = self._read()
        if store.pop(self._account, None) is not None:
            self._write(store)

    def call(self, wsfunction: str, **args: Any) -> Any:
        params = {
            "moodlewsrestformat": "json",
            "wsfunction": wsfunction,
            "wstoken": self.get_token()["wstoken"],
        }
        r = self._client.post(
            f"{SITE_URL}/webservice/rest/server.php", params=params, data=args,
        )
        r.raise_for_status()
        return r.json()

    # ---- OIDC flow (HAR-aligned 3-step) ----

    def _login(self) -> dict[str, Any]:
        return self._exchange_code_for_token(
            self._submit_credentials(self._go_to_login_page())
        )

    def _go_to_login_page(self) -> httpx.Response:
        url = (
            f"{SITE_URL}/admin/tool/mobile/launch.php"
            f"?service={SERVICE}&passport={random.random() * 1000}"
            f"&urlscheme={URL_SCHEME}"
        )
        logger.info("[1] GET launch %s", url)
        resp = self._client.get(url)
        resp.raise_for_status()
        if "ssoam2.ntust.edu.tw" not in str(resp.url):
            raise MoodleOidcAuthError(f"Expected SSO login page, got {resp.url}")
        return resp

    def _submit_credentials(self, login_page: httpx.Response) -> httpx.Response:
        form = _parse_login_form(login_page.text)
        if not form["antiforgery"]:
            raise MoodleOidcAuthError("AntiForgery token missing — page shape changed")
        action = urljoin(str(login_page.url), form["action"])
        logger.info("[6] POST %s (Username=%s)", action, self._account)
        resp = self._client.post(
            action,
            data={
                "__RequestVerificationToken": form["antiforgery"],
                "Username": self._account,
                "Password": self._password,
                "captcha": "",
                "cf-turnstile-response": "",
                "h-captcha-response": "",
                "g-recaptcha-response": "",
                "ClientId": form["client_id"],
                "ReturnUrl": form["return_url"],
                "Uri": form["uri"],
            },
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Referer": str(login_page.url),
                "Origin": SSO_URL,
            },
        )
        resp.raise_for_status()
        if "/account/login" in str(resp.url):
            err = _extract_login_error(resp.text) or "bad credentials or account locked"
            raise MoodleOidcAuthError(f"SSO login rejected: {err}")
        return resp

    def _exchange_code_for_token(self, authorize_page: httpx.Response) -> dict[str, Any]:
        bridge = _parse_oidc_form_post(authorize_page.text)
        if not bridge:
            raise MoodleOidcAuthError(
                f"Expected OIDC form_post bridge, landed on {authorize_page.url}"
            )
        logger.info("[8] POST %s", bridge["action"])
        resp = self._client.post(bridge["action"], data=bridge["payload"])
        resp.raise_for_status()

        m = re.search(r"moodlemobile://token=([A-Za-z0-9+/=_-]+)", resp.text)
        if not m:
            raise MoodleOidcAuthError("Final launch page missing moodlemobile://token=")
        try:
            decoded = base64.b64decode(m.group(1)).decode("ascii")
        except Exception as e:
            raise MoodleOidcAuthError(f"Failed to base64-decode token: {e}") from e

        parts = decoded.split(":::")
        if len(parts) != 3:
            raise MoodleOidcAuthError(f"Unexpected token triple ({len(parts)} parts)")
        sig, wstoken, privatetoken = parts
        return {
            "account": self._account,
            "signature": sig,
            "wstoken": wstoken,
            "privatetoken": privatetoken,
            "site_url": SITE_URL,
            "service": SERVICE,
            "obtained_at": int(time.time()),
        }

    # ---- persistence ----

    def _read(self) -> dict[str, dict[str, Any]]:
        if not self._token_path.exists():
            return {}
        try:
            data = json.loads(self._token_path.read_text("utf-8"))
            return data if isinstance(data, dict) else {}
        except json.JSONDecodeError:
            logger.warning("Corrupt token store at %s, resetting", self._token_path)
            return {}

    def _write(self, store: dict[str, dict[str, Any]]) -> None:
        self._token_path.write_text(
            json.dumps(store, indent=2, ensure_ascii=False) + "\n", "utf-8",
        )
        try:
            os.chmod(self._token_path, 0o600)
        except OSError:
            pass


# ---------------- CLI ----------------

def _mask(v: str, keep: int = 6) -> str:
    return "***" if len(v) <= keep * 2 else f"{v[:keep]}...{v[-keep:]}"


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s",
    )
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as c:
        tok = c.get_token(force_refresh="--refresh" in sys.argv[1:])
        print("=== Token (masked) ===")
        print(json.dumps(
            {**tok, **{k: _mask(tok[k]) for k in ("signature", "wstoken", "privatetoken")}},
            indent=2, ensure_ascii=False,
        ))
        info = c.call("core_webservice_get_site_info")
        if isinstance(info, dict) and "errorcode" in info:
            print(f"[FAIL] {info}", file=sys.stderr)
            return 3
        print("=== core_webservice_get_site_info ===")
        keep = ("sitename", "username", "fullname", "userid", "release", "lang")
        print(json.dumps(
            {k: info[k] for k in keep if k in info}, indent=2, ensure_ascii=False,
        ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
