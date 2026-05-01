"""Pure-unit tests for `build_fcm_alert_request`.

FCM rejects messages whose `data` map contains non-string values, so the
builder must stringify everything (notably `bulletin_id`). These tests
pin that contract.
"""

from __future__ import annotations

from server.push.payload import FcmRequest, build_fcm_alert_request


def test_data_values_are_all_strings() -> None:
    req = build_fcm_alert_request(
        fcm_token="fcm-tok",
        title="t",
        body="b",
        bulletin_id=42,
        source_url="https://x/42",
        canonical_org="oaa",
    )
    assert isinstance(req, FcmRequest)
    assert req.token == "fcm-tok"
    assert req.title == "t"
    assert req.body == "b"
    assert req.data == {
        "bulletin_id": "42",
        "source_url": "https://x/42",
        "canonical_org": "oaa",
    }
    assert all(isinstance(v, str) for v in req.data.values())


def test_bulletin_id_is_stringified_int() -> None:
    req = build_fcm_alert_request(
        fcm_token="t",
        title="t",
        body="b",
        bulletin_id=7,
        source_url="",
        canonical_org="",
    )
    assert req.data["bulletin_id"] == "7"
    # round-trip — Android client parses back to int.
    assert int(req.data["bulletin_id"]) == 7


def test_default_ttl_is_seven_days() -> None:
    req = build_fcm_alert_request(
        fcm_token="t",
        title="t",
        body="b",
        bulletin_id=1,
        source_url="",
        canonical_org="",
    )
    assert req.ttl_seconds == 7 * 24 * 3600
