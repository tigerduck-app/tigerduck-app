"""Campus webmail probe for mail.ntust.edu.tw (Openfind Mail2000 V8).

Not HTTP: this one is IMAP and SMTP, so it runs on `imaplib`/`smtplib` from
the standard library and needs no extra dependency.

## Transport

Implicit TLS only. IMAP is 993 and SMTP is 465; ports 587 and 25 are not
reachable from outside, so STARTTLS is a dead end on this server.

## Folder discovery

The server does not advertise SPECIAL-USE, so there is no way to ask which
mailbox is Sent or Trash. Only `INBOX` is guaranteed (RFC 3501); everything
else has to be discovered with `LIST` and matched by name.

## UIDs are per-mailbox

An IMAP UID is unique within one mailbox, not across the account. Any
whole-account search therefore has to carry the folder with each hit —
reusing the currently selected folder to open, flag or move a result will
silently act on a different message once the UIDs collide.

## Timeouts are mandatory

The server drops idle connections ("auto logout; idle for too long"). A
connect timeout does not cover it: the TCP+TLS handshake finishing says
nothing about `LOGIN`, `SELECT`, `FETCH` or `APPEND` ever answering. Give the
socket a timeout so a dropped connection surfaces as an error instead of a
wait that never ends.

Sending is behind `--send` and prints the message instead of delivering it
unless `--commit` is also passed.
"""

from __future__ import annotations

import argparse
import email
import imaplib
import json
import smtplib
import ssl
import sys
from email.header import decode_header
from email.message import EmailMessage

from api import load_creds

HOST = "mail.ntust.edu.tw"
IMAP_PORT = 993
SMTP_PORT = 465
INBOX = "INBOX"

# The server has no SPECIAL-USE, so the socket timeout is the only thing
# standing between a dropped connection and a hang.
SOCKET_TIMEOUT = 30.0

def decode_mailbox_name(name: str) -> str:
    """Decode RFC 3501 modified UTF-7, which imaplib hands back untouched.

    Folder names arrive as e.g. `&W8RO9lCZTv1TIw-`. It is UTF-7 with two
    substitutions: `&` shifts instead of `+`, and `,` stands in for `/` in the
    base64 alphabet. `&-` is a literal `&`.
    """
    parts = name.split("&")
    out = [parts[0]]
    for part in parts[1:]:
        if part.startswith("-"):
            out.append("&" + part[1:])
            continue
        encoded, _, rest = part.partition("-")
        try:
            out.append(
                ("+" + encoded.replace(",", "/") + "-").encode("ascii").decode("utf-7")
            )
        except (UnicodeDecodeError, UnicodeEncodeError):
            # Leave an undecodable name visible rather than dropping the folder.
            out.append("&" + part)
            continue
        out.append(rest)
    return "".join(out)


def decode_header_value(value: str) -> str:
    """Decode an RFC 2047 header. This server still emits big5 subjects."""
    if not value:
        return ""
    out = []
    for chunk, charset in decode_header(value):
        if isinstance(chunk, bytes):
            try:
                out.append(chunk.decode(charset or "utf-8", "replace"))
            except LookupError:
                out.append(chunk.decode("utf-8", "replace"))
        else:
            out.append(chunk)
    return "".join(out)


def _address(student_id: str) -> str:
    return f"{student_id.strip().lower()}@{HOST.split('.', 1)[1]}"


def parse_list_line(line: bytes | str) -> dict[str, str] | None:
    """Pull flags/delimiter/name out of one LIST response line.

    imaplib hands most untagged responses back as bytes but not all of them,
    so both are accepted rather than coerced — `bytes(str)` raises.
    """
    text = line.decode("utf-8", "replace") if isinstance(line, bytes) else line
    if not text.startswith("("):
        return None
    flags, _, rest = text.partition(")")
    delimiter, _, name = rest.strip().partition(" ")
    raw_name = name.strip().strip('"')
    return {
        "flags": flags.lstrip("("),
        "delimiter": delimiter.strip('"'),
        "raw_name": raw_name,
        "name": decode_mailbox_name(raw_name),
    }


def probe_imap(student_id: str, password: str, limit: int) -> dict[str, object]:
    """LIST the folders, then read the newest headers out of INBOX."""
    report: dict[str, object] = {"host": HOST, "imap_port": IMAP_PORT}
    context = ssl.create_default_context()
    with imaplib.IMAP4_SSL(
        HOST, IMAP_PORT, ssl_context=context, timeout=SOCKET_TIMEOUT,
    ) as imap:
        imap.login(student_id, password)
        # imaplib hands capabilities back as str, unlike every other response.
        capabilities = list(imap.capabilities)
        report["capabilities"] = capabilities
        # SPECIAL-USE is expected to be absent; record it either way so a
        # server upgrade is visible rather than assumed.
        report["has_special_use"] = any(
            "SPECIAL-USE" in c.upper() for c in capabilities
        )

        status, lines = imap.list()
        folders = []
        if status == "OK":
            for line in lines:
                parsed = parse_list_line(line)
                if parsed:
                    folders.append(parsed)
        report["folders"] = folders

        status, data = imap.select(INBOX, readonly=True)
        if status != "OK":
            report["inbox_error"] = data[0].decode("utf-8", "replace")
            return report

        status, data = imap.uid("search", None, "ALL")
        uids = data[0].split() if status == "OK" and data and data[0] else []
        report["inbox_count"] = len(uids)

        messages = []
        for uid in uids[-limit:][::-1]:
            status, fetched = imap.uid(
                "fetch", uid,
                "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)] FLAGS)",
            )
            if status != "OK" or not fetched or not isinstance(fetched[0], tuple):
                continue
            headers = email.message_from_bytes(fetched[0][1])
            messages.append({
                # The folder travels with the UID; see the module docstring.
                "folder": INBOX,
                "uid": uid.decode(),
                "from": decode_header_value(headers.get("From", "")),
                "subject": decode_header_value(headers.get("Subject", "")),
                "date": headers.get("Date", ""),
            })
        report["messages"] = messages
    return report


def build_message(sender: str, to: str, subject: str, body: str) -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)
    return msg


def send_message(
    student_id: str,
    password: str,
    msg: EmailMessage,
) -> None:
    context = ssl.create_default_context()
    with smtplib.SMTP_SSL(
        HOST, SMTP_PORT, context=context, timeout=SOCKET_TIMEOUT,
    ) as smtp:
        smtp.login(student_id, password)
        smtp.send_message(msg)


def main() -> int:
    parser = argparse.ArgumentParser(prog="python -m api.ntust.webmail")
    parser.add_argument("--limit", type=int, default=10,
                        help="how many recent INBOX headers to read")
    parser.add_argument("--send", metavar="TO",
                        help="compose a message to this address")
    parser.add_argument("--subject", default="NTUST webmail probe")
    parser.add_argument("--body", default="Sent by api.ntust.webmail.")
    parser.add_argument("--commit", action="store_true",
                        help="actually deliver the --send message")
    args = parser.parse_args()
    # uids[-limit:] silently means "everything" at 0 and "all but the first n"
    # at -n, so an invalid count would widen the read instead of narrowing it.
    if args.limit < 1:
        parser.error("--limit must be at least 1")

    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    if args.send:
        msg = build_message(_address(sid), args.send, args.subject, args.body)
        if not args.commit:
            print(json.dumps({
                "dry_run": True,
                "smtp": f"{HOST}:{SMTP_PORT} (implicit TLS)",
                "from": msg["From"],
                "to": msg["To"],
                "subject": msg["Subject"],
                "body": args.body,
                "hint": "re-run with --commit to actually send this",
            }, ensure_ascii=False, indent=2))
            return 0
        send_message(sid, pwd, msg)
        print(json.dumps({"sent": True, "to": args.send}, ensure_ascii=False))
        return 0

    try:
        report = probe_imap(sid, pwd, args.limit)
    except (imaplib.IMAP4.error, OSError) as e:
        print(f"[FAIL] {type(e).__name__}: {e}", file=sys.stderr)
        return 3
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


def _self_check() -> None:
    assert parse_list_line(b'(\\HasNoChildren) "/" "INBOX"') == {
        "flags": "\\HasNoChildren", "delimiter": "/",
        "raw_name": "INBOX", "name": "INBOX",
    }
    assert parse_list_line(b"NO such mailbox") is None
    # imaplib does not guarantee bytes for every untagged line; a str must
    # parse rather than blow up on a bytes() coercion.
    assert parse_list_line('(\\HasNoChildren) "/" "INBOX"') == {
        "flags": "\\HasNoChildren", "delimiter": "/",
        "raw_name": "INBOX", "name": "INBOX",
    }

    # Modified UTF-7: '&' shifts, ',' replaces '/', '&-' is a literal '&'.
    assert decode_mailbox_name("INBOX") == "INBOX"
    assert decode_mailbox_name("Trash/Notes") == "Trash/Notes"
    assert decode_mailbox_name("&-") == "&"
    assert decode_mailbox_name("A&-B") == "A&B"
    assert decode_mailbox_name("&g0l6P1Mj-") == "\u8349\u7a3f\u5323"
    assert decode_mailbox_name("&W8RO9lCZTv1TIw-") == "\u5bc4\u4ef6\u5099\u4efd\u5323"
    # ',' stands in for '/' inside the base64 run.
    assert decode_mailbox_name("&XuNUSk,hUyM-") == "\u5ee3\u544a\u4fe1\u5323"
    # A trailing segment after the shift must survive.
    assert decode_mailbox_name("&g0l6P1Mj-/sub") == "\u8349\u7a3f\u5323/sub"

    # RFC 2047, including the big5 this server still emits.
    assert decode_header_value("") == ""
    assert decode_header_value("plain subject") == "plain subject"
    assert decode_header_value("=?utf-8?B?5ris6Kmm?=") == "\u6e2c\u8a66"
    assert decode_header_value("[X] =?big5?B?rOO1bw==?=") == "[X] \u7814\u767c"
    assert decode_header_value("=?big5?B?sdCwyLNC?=") == "\u6559\u52d9\u8655"

    msg = build_message("a@ntust.edu.tw", "b@example.com", "S", "B")
    assert msg["From"] == "a@ntust.edu.tw" and msg["To"] == "b@example.com"
    assert msg.get_content().strip() == "B"
    assert _address(" B00000000 ") == "b00000000@ntust.edu.tw"
    print("self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        sys.exit(0)
    sys.exit(main())
