"""Pinning the platform-aware classifier in `bulletins/dispatcher.py`.

The dispatcher uses `_classify` to decide whether a failed send should
flip the dispatch row to `bad_token` (drop the device) or stay
retry-eligible. APNs and FCM speak different error vocabularies, so the
classifier is parameterised by platform — these tests guard the FCM
branch specifically.
"""

from __future__ import annotations

from server.bulletins.dispatcher import _classify
from server.push.apns_client import SendResult


def _fail(status: str, description: str = "") -> SendResult:
    return SendResult(success=False, status=status, description=description)


def test_android_unregistered_is_bad_token() -> None:
    assert _classify(_fail("UNREGISTERED", "token not registered"), platform="android") == "bad_token"


def test_android_sender_id_mismatch_is_bad_token() -> None:
    assert _classify(_fail("SENDER_ID_MISMATCH"), platform="android") == "bad_token"


def test_android_invalid_argument_is_bad_token() -> None:
    assert _classify(_fail("INVALID_ARGUMENT"), platform="android") == "bad_token"


def test_android_unknown_status_is_transient() -> None:
    assert _classify(_fail("UNKNOWN", "boom"), platform="android") == "transient"


def test_android_quota_exceeded_is_transient() -> None:
    # Surface the firebase-admin transient bucket as retry-eligible.
    assert _classify(_fail("TRANSIENT", "rate limited"), platform="android") == "transient"


def test_apple_410_is_bad_token() -> None:
    # Existing APNs behaviour — keep a regression pin alongside the FCM ones.
    assert _classify(_fail("410", "Unregistered"), platform="apple") == "bad_token"


def test_success_is_sent_regardless_of_platform() -> None:
    ok = SendResult(success=True, status="200")
    assert _classify(ok, platform="apple") == "sent"
    assert _classify(ok, platform="android") == "sent"
