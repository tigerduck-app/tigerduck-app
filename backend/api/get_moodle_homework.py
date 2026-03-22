import json
import os
import re

from ntust_sso import NtustSsoBridge

MOODLE_LOGIN_URL = "https://moodle2.ntust.edu.tw/login/index.php"
HOMEWORKS_URL = "https://moodle2.ntust.edu.tw/lib/ajax/service.php?sesskey={sesskey}&info=core_calendar_get_action_events_by_timesort"
PAYLOAD = [
    {
        "index": 0,
        "methodname": "core_calendar_get_action_events_by_timesort",
        "args": {
            "limitnum": 50,
            "timesortfrom": 1772899200,
            "limittononsuspendedevents": True,
        },
    }
]

if __name__ == "__main__":
    student_id = os.getenv("STUDENT_ID")
    password = os.getenv("PASSWORD")

    if not student_id or not password:
        raise RuntimeError("Missing STUDENT_ID or PASSWORD environment variables")

    with NtustSsoBridge(student_id, password) as bridge:
        # Login via SSO and get sesskey in one pass
        # /login/index.php is lightweight and forces SSO redirect,
        # final redirect lands on authenticated page containing sesskey
        if not bridge.ensure_service_login(MOODLE_LOGIN_URL):
            raise RuntimeError("SSO login failed")

        resp = bridge.open(MOODLE_LOGIN_URL)
        match = re.search(r'"sesskey":"([^"]+)"', resp.text)
        if not match:
            raise RuntimeError("Failed to extract sesskey from Moodle page")
        sesskey = match.group(1)
        print(f"sesskey: {sesskey}")

        # Step 3: Call calendar API
        url = HOMEWORKS_URL.format(sesskey=sesskey)
        resp = bridge.client.post(
            url,
            json=PAYLOAD,
            headers={"Content-Type": "application/json"},
        )
        resp.raise_for_status()

        print(json.dumps(resp.json(), ensure_ascii=False, indent=2))
