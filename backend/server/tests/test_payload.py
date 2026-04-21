"""Payload builder unit tests — shape and header correctness."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from server.push.payload import (
    SCENARIO_ASSIGNMENT_URGENT,
    SCENARIO_CLASS_PREPARING,
    SCENARIO_IN_CLASS,
    build_apns_request,
    build_pts_payload,
)


FIXED_NOW = datetime(2026, 4, 22, 2, 0, 0, tzinfo=timezone.utc)


def _sample_snapshot(**overrides) -> dict:
    base = {
        "scenario": SCENARIO_CLASS_PREPARING,
        "title": "計算機程式設計",
        "subtitle": "10:10-12:00",
        "locationText": "T2-401",
        "instructor": "王小明",
        "countdownTarget": "2026-04-22T02:10:00+00:00",
        "progressStart": None,
        "accentHex": 0x4A90E2,
        "deepLink": None,
        "sourceId": "slot-123",
    }
    base.update(overrides)
    return base


def test_build_pts_payload_minimum_shape():
    snapshot = _sample_snapshot()
    payload = build_pts_payload(
        scenario=SCENARIO_CLASS_PREPARING,
        source_id="slot-123",
        snapshot=snapshot,
        now=FIXED_NOW,
    )
    aps = payload["aps"]
    assert aps["event"] == "start"
    assert aps["attributes-type"] == "TigerDuckActivityAttributes"
    assert aps["attributes"] == {"activityId": "slot-123"}
    assert aps["content-state"] == {"snapshot": snapshot}
    assert aps["timestamp"] == int(FIXED_NOW.timestamp())
    assert "alert" in aps


@pytest.mark.parametrize(
    "scenario,expected_title_prefix",
    [
        (SCENARIO_CLASS_PREPARING, "即將上課"),
        (SCENARIO_IN_CLASS, "上課中"),
        (SCENARIO_ASSIGNMENT_URGENT, "作業即將到期"),
    ],
)
def test_alert_reflects_scenario(scenario, expected_title_prefix):
    snapshot = _sample_snapshot(title="Algorithms")
    payload = build_pts_payload(
        scenario=scenario,
        source_id="slot-x",
        snapshot=snapshot,
        now=FIXED_NOW,
    )
    alert = payload["aps"]["alert"]
    assert alert["title"].startswith(expected_title_prefix)
    assert "Algorithms" in alert["title"]


def test_build_apns_request_headers():
    fire_at = FIXED_NOW + timedelta(minutes=15)
    request = build_apns_request(
        device_token="aabbccdd" * 8,
        bundle_id="org.ntust.app.TigerDuck",
        scenario=SCENARIO_CLASS_PREPARING,
        source_id="slot-42",
        fire_at=fire_at,
        snapshot=_sample_snapshot(),
        now=FIXED_NOW,
    )
    # topic MUST have the .push-type.liveactivity suffix or APNs rejects
    assert request.topic == "org.ntust.app.TigerDuck.push-type.liveactivity"
    assert request.priority == 10
    # expiration = fire_at + slack
    assert request.expiration == int(fire_at.timestamp()) + 60
    assert request.message["aps"]["event"] == "start"
    assert request.message["aps"]["attributes"]["activityId"] == "slot-42"


def test_expiration_slack_customizable():
    fire_at = FIXED_NOW + timedelta(minutes=15)
    request = build_apns_request(
        device_token="t" * 64,
        bundle_id="org.ntust.app.TigerDuck",
        scenario=SCENARIO_IN_CLASS,
        source_id="slot-42",
        fire_at=fire_at,
        snapshot=_sample_snapshot(),
        expiration_slack_seconds=300,
        now=FIXED_NOW,
    )
    assert request.expiration == int(fire_at.timestamp()) + 300


def test_custom_attrs_type_reflected():
    request = build_apns_request(
        device_token="t" * 64,
        bundle_id="org.ntust.app.TigerDuck",
        scenario=SCENARIO_CLASS_PREPARING,
        source_id="slot-42",
        fire_at=FIXED_NOW + timedelta(minutes=5),
        snapshot=_sample_snapshot(),
        attrs_type="SomeOtherAttributes",
        now=FIXED_NOW,
    )
    assert request.message["aps"]["attributes-type"] == "SomeOtherAttributes"
