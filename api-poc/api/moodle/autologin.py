"""Moodle browser-handoff probe: turn a webservice token into a web session.

`tool_mobile_get_autologin_key` trades the `privatetoken` (issued alongside
the wstoken by the OIDC launch flow) for a one-shot key. Opening
`/admin/tool/mobile/autologin.php?userid=&key=&urltogo=` with that key sets a
normal Moodle session cookie and 303s to `urltogo`, so an in-app browser can
land on a course page already logged in.

Three constraints the server enforces and the response does not explain:

* The request must carry a user agent containing `MoodleMobile` — the server
  does a case-insensitive substring match and refuses anything else.
* `autologinmintimebetweenreq` (default 360s) rate-limits key issuance per
  user. Inside that window every call returns a lockout error, and the
  timestamp is recorded server-side whether or not the key is ever used.
* `autologinurl` comes back *in the response body*. Opening it carries
  cookies, so it must be checked against the expected https host before use
  rather than trusted as given.

Also probed here: `tokenpluginfile.php`. Moodle serves course files from
`[/webservice]/pluginfile.php`, which needs credentials. Appending
`?token=<wstoken>` works but puts the long-lived token into every URL, and
therefore into proxy logs and `Referer` headers. Rewriting the path to
`/tokenpluginfile.php/<userprivateaccesskey>` avoids that: the access key is
per-user, scoped to file serving, and rotatable. The query string has to
survive the rewrite untouched (`forcedownload=1` and friends are load-bearing).
"""

from __future__ import annotations

import json
import re
import sys
from urllib.parse import urlencode, urlparse, urlsplit, urlunsplit

from api import load_creds
from api.moodle.auth import SITE_URL, MoodleOidcAuthClient

AUTOLOGIN_WSFUNCTION = "tool_mobile_get_autologin_key"
SITE_INFO_WSFUNCTION = "core_webservice_get_site_info"
AUTOLOGIN_SCRIPT_PATH = "/admin/tool/mobile/autologin.php"

MOODLE_HOST = urlparse(SITE_URL).hostname or ""
PLUGINFILE_SEGMENT = re.compile(r"(/webservice)?/pluginfile\.php")


def _is_error(payload: object) -> bool:
    return isinstance(payload, dict) and bool(payload.get("errorcode"))


def fetch_autologin_key(client: MoodleOidcAuthClient) -> object:
    """Ask for a one-shot autologin key. Rate-limited; see module docstring."""
    return client.call(
        AUTOLOGIN_WSFUNCTION,
        privatetoken=client.get_token()["privatetoken"],
    )


def build_autologin_url(
    autologin_url: str,
    key: str,
    user_id: str,
    target: str,
) -> str | None:
    """Assemble the handoff URL, refusing one that points off-site."""
    parts = urlsplit(autologin_url)
    if parts.scheme != "https" or parts.hostname != MOODLE_HOST:
        return None
    if not (key and user_id and target):
        return None
    query = urlencode({"userid": user_id, "key": key, "urltogo": target})
    return urlunsplit((parts.scheme, parts.netloc, parts.path, query, ""))


def token_pluginfile_url(file_url: str, access_key: str) -> str | None:
    """Rewrite a pluginfile URL to the tokenpluginfile form, or None."""
    if not access_key:
        return None
    path, sep, query = file_url.partition("?")
    # A URL that already carries ?token= is left alone: tokenpluginfile does
    # not accept the wstoken, so rewriting would produce a URL holding both
    # credentials and leak the token anyway.
    if "token=" in query:
        return None
    match = PLUGINFILE_SEGMENT.search(path)
    if not match:
        return None
    rewritten = (
        f"{path[:match.start()]}/tokenpluginfile.php/{access_key}"
        f"{path[match.end():]}"
    )
    return rewritten + sep + query


def main() -> int:
    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    target = sys.argv[1] if len(sys.argv) > 1 else f"{SITE_URL}/my/"

    with MoodleOidcAuthClient(sid, pwd) as client:
        site_info = client.call(SITE_INFO_WSFUNCTION)
        if _is_error(site_info):
            print(f"[FAIL] {site_info}", file=sys.stderr)
            return 3

        result = fetch_autologin_key(client)
        if _is_error(result):
            # A lockout here is the expected answer inside the 6-minute
            # window, not a broken script.
            print(f"[FAIL] {result}", file=sys.stderr)
            return 3

        handoff = build_autologin_url(
            result.get("autologinurl", ""),
            result.get("key", ""),
            str(site_info["userid"]),
            target,
        )

        access_key = site_info.get("userprivateaccesskey", "")
        sample = f"{SITE_URL}/webservice/pluginfile.php/123/mod_resource/content/0/a.pdf?forcedownload=1"

        print(json.dumps({
            "script_path": AUTOLOGIN_SCRIPT_PATH,
            "key_issued": bool(result.get("key")),
            "autologinurl": result.get("autologinurl"),
            "handoff_url_valid": handoff is not None,
            "pluginfile_sample": sample,
            "tokenpluginfile_sample": token_pluginfile_url(sample, access_key),
        }, ensure_ascii=False, indent=2))
    return 0


def _self_check() -> None:
    """Rewriting rules are pure string surgery — check them without network."""
    ok = f"https://{MOODLE_HOST}/webservice/pluginfile.php/1/x.pdf?forcedownload=1"
    got = token_pluginfile_url(ok, "KEY")
    assert got == f"https://{MOODLE_HOST}/tokenpluginfile.php/KEY/1/x.pdf?forcedownload=1", got
    assert token_pluginfile_url(ok, "") is None
    assert token_pluginfile_url(f"{ok}&token=abc", "KEY") is None
    assert token_pluginfile_url(f"https://{MOODLE_HOST}/course/view.php?id=1", "KEY") is None
    # Bare /pluginfile.php (no /webservice prefix) rewrites the same way.
    bare = f"https://{MOODLE_HOST}/pluginfile.php/1/x.pdf"
    assert token_pluginfile_url(bare, "KEY") == f"https://{MOODLE_HOST}/tokenpluginfile.php/KEY/1/x.pdf"

    assert build_autologin_url(f"https://{MOODLE_HOST}{AUTOLOGIN_SCRIPT_PATH}", "k", "7", "https://x/") is not None
    assert build_autologin_url("https://evil.example/autologin.php", "k", "7", "https://x/") is None
    assert build_autologin_url(f"http://{MOODLE_HOST}{AUTOLOGIN_SCRIPT_PATH}", "k", "7", "https://x/") is None
    assert build_autologin_url(f"https://{MOODLE_HOST}{AUTOLOGIN_SCRIPT_PATH}", "", "7", "https://x/") is None
    print("self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        sys.exit(0)
    sys.exit(main())
