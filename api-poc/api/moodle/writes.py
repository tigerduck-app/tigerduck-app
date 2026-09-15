"""Moodle write-endpoint payload reference. Dry-run by default.

Every entry below is a `type=write` webservice function: calling it for real
changes state on a live account, and some of it is visible to classmates and
teachers (a forum post) or irreversible from the client (submitting for
grading). So this script prints the exact payload it *would* send and stops.
Pass `--commit` to actually send one.

## Response shapes are not uniform

Moodle reports failure with HTTP 200 throughout. There are three different
success/failure envelopes among these functions, and confusing them means
treating a failed write as a successful one:

* `{exception, errorcode, message}` — the request never ran.
* a **bare warnings array** — `mod_assign_save_submission` and
  `mod_assign_submit_for_grading`. Empty array means success.
* a **object** `{status, warnings}` — `mod_assign_remove_submission`,
  `mod_forum_delete_post`. `status != true` is failure even with no warnings.

`mod_assign_start_submission` overloads warnings as an outcome channel:
`opensubmissionexists` means an attempt was already running (continue into
it), `timelimitnotenabled` means the site-level `enabletimelimit` is off (no
webservice exposes that flag, this warning is the only signal), and only
`submissionnotopen` is a real failure.

## Parameter naming is inconsistent on purpose-built endpoints

`mod_assign_remove_submission` takes `assignid` (plus `userid`), while
`mod_assign_submit_for_grading` and `mod_assign_copy_previous_attempt` take
`assignmentid`. `mod_assign_start_submission` takes `assignid`. There is no
rule here; the names must be copied per function.

## Two that carry ethical weight

* `acceptsubmissionstatement` must only be 1 when the user genuinely ticked
  the box. The server raises a `statement_accepted` audit event from it, so
  hardcoding 1 forges a consent record.
* `mod_assign_copy_previous_attempt` is outside
  MOODLE_OFFICIAL_MOBILE_SERVICE, so most sites will not list it in
  `site_info.functions[]`. Absent is the normal case, not an error.
"""

from __future__ import annotations

import json
import sys

from api import load_creds
from api.moodle.auth import MoodleOidcAuthClient

# FORMAT_HTML. onlinetext's format field is PARAM_INT, not a string.
FORMAT_HTML = 1
FORMAT_PLAIN = 2

# name -> (payload template, response envelope, one-line note)
WRITES: dict[str, tuple[dict[str, object], str, str]] = {
    "mod_assign_save_submission": (
        {
            "assignmentid": "<assignid>",
            "plugindata[onlinetext_editor][text]": "<html>",
            "plugindata[onlinetext_editor][format]": FORMAT_HTML,
            "plugindata[onlinetext_editor][itemid]": "<draftitemid>",
            "plugindata[files_filemanager]": "<draftitemid>",
        },
        "bare warnings array",
        "Saves a draft. itemid is a draft area id from webservice/upload.php.",
    ),
    "mod_assign_start_submission": (
        {"assignid": "<assignid>"},
        "object {submissionid, warnings}",
        "Starts the timer. Warnings encode the outcome; see module docstring.",
    ),
    "mod_assign_submit_for_grading": (
        {"assignmentid": "<assignid>", "acceptsubmissionstatement": 0},
        "bare warnings array",
        "Irreversible for the student. Only pass 1 on a real tick.",
    ),
    "mod_assign_remove_submission": (
        {"assignid": "<assignid>", "userid": "<userid>"},
        "object {status, warnings}",
        "@since Moodle 4.5. Note assignid, not assignmentid.",
    ),
    "mod_assign_copy_previous_attempt": (
        {"assignmentid": "<assignid>"},
        "bare warnings array",
        "Usually absent from site_info.functions[]; that is normal.",
    ),
    "mod_forum_add_discussion_post": (
        {
            "postid": "<parent postid>",
            "subject": "<subject>",
            "message": "<body>",
            "messageformat": FORMAT_PLAIN,
            "options[0][name]": "topreferredformat",
            "options[0][value]": "1",
            "options[1][name]": "attachmentsid",
            "options[1][value]": "<draftitemid>",
        },
        "object",
        "Visible to the whole course. postid is the post being replied to.",
    ),
    "mod_forum_update_discussion_post": (
        {
            "postid": "<postid>",
            "subject": "<subject>",
            "message": "<body>",
            "messageformat": FORMAT_HTML,
            "options[0][name]": "<option>",
            "options[0][value]": "<value>",
        },
        "object {status, warnings}",
        "Send stored text, never rendered output. See forum_posts.py.",
    ),
    "mod_forum_delete_post": (
        {"postid": "<postid>"},
        "object {status, warnings}",
        "Deletes the whole thread when the post has no parent.",
    ),
    "mod_forum_prepare_draft_area_for_post": (
        {
            "postid": "<postid>",
            "area": "attachment",
            "draftitemid": 0,
            "filestokeep[0][filename]": "<name>",
            "filestokeep[0][filepath]": "/",
        },
        "object",
        "Copies existing attachments into a draft area before an edit.",
    ),
    "core_user_update_picture": (
        {"draftitemid": "<draftitemid>", "delete": 0},
        "object",
        "@since Moodle 3.2. delete=1 removes the picture and ignores itemid.",
    ),
    "core_user_update_user_preferences": (
        {
            "preferences[0][type]": "<key>_enabled",
            "preferences[0][value]": "<comma,separated,providers>",
        },
        "null + warnings",
        "Any warning means the preference did not persist.",
    ),
    "core_message_mark_notification_read": (
        {"notificationid": "<notificationid>"},
        "object",
        "Single notification.",
    ),
    "core_message_mark_all_notifications_as_read": (
        {"useridto": "<userid>"},
        "boolean",
        "useridto must be a real id; 0 is not the current user here.",
    ),
}


def describe() -> str:
    rows = []
    for name, (payload, envelope, note) in WRITES.items():
        rows.append({
            "wsfunction": name,
            "payload": payload,
            "response": envelope,
            "note": note,
        })
    return json.dumps(rows, ensure_ascii=False, indent=2)


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--commit"]
    commit = "--commit" in sys.argv[1:]

    if not args:
        print(describe())
        return 0

    name = args[0]
    if name not in WRITES:
        print(f"unknown wsfunction: {name}", file=sys.stderr)
        print(f"known: {', '.join(WRITES)}", file=sys.stderr)
        return 2

    payload_template, envelope, note = WRITES[name]
    overrides = {}
    for pair in args[1:]:
        k, sep, v = pair.partition("=")
        if not sep:
            print(f"arguments must be key=value, got {pair!r}", file=sys.stderr)
            return 2
        overrides[k] = v
    payload = {**payload_template, **overrides}

    if not commit:
        print(json.dumps({
            "dry_run": True,
            "wsfunction": name,
            "payload": payload,
            "expected_response": envelope,
            "note": note,
            "hint": "re-run with --commit to send this for real",
        }, ensure_ascii=False, indent=2))
        return 0

    unresolved = [k for k, v in payload.items() if isinstance(v, str) and v.startswith("<")]
    if unresolved:
        print(f"[FAIL] placeholders left unset: {unresolved}", file=sys.stderr)
        return 2

    try:
        sid, pwd = load_creds()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 2

    with MoodleOidcAuthClient(sid, pwd) as client:
        result = client.call(name, **payload)
        print(json.dumps(result, ensure_ascii=False))
        if isinstance(result, dict) and result.get("errorcode"):
            return 3
        # A bare warnings array is only a success when it is empty.
        if isinstance(result, list) and result:
            print(f"[WARN] {name} returned warnings", file=sys.stderr)
            return 3
        if isinstance(result, dict) and result.get("status") is False:
            print(f"[WARN] {name} returned status=false", file=sys.stderr)
            return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
