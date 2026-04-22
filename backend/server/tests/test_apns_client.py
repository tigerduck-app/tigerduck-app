"""APNs client factory tests — does NOT hit Apple's servers."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from server.config import Settings
from server.push.apns_client import (
    AioApnsSender,
    RecordingSender,
    build_sender,
)
from server.push.payload import SCENARIO_CLASS_PREPARING, build_apns_request


def _no_apns_settings() -> Settings:
    return Settings(apns_team_id="", apns_key_id="")


def _fake_apns_settings(key_path) -> Settings:
    return Settings(
        apns_team_id="TEAM1234AB",
        apns_key_id="KEY1234ABC",
        apns_key_path=key_path,
    )


def test_build_sender_returns_recording_when_unconfigured():
    sender = build_sender(_no_apns_settings())
    assert isinstance(sender, RecordingSender)


def test_build_sender_errors_when_key_missing(tmp_path):
    missing = tmp_path / "does_not_exist.p8"
    # key_id/team_id set but file missing → falls back to recording
    sender = build_sender(_fake_apns_settings(missing))
    assert isinstance(sender, RecordingSender)


def test_aioapns_sender_rejects_partial_config(tmp_path):
    # key_id set, team_id missing → AioApnsSender() itself should raise
    bad = Settings(apns_team_id="", apns_key_id="KEY1234ABC")
    with pytest.raises(ValueError):
        AioApnsSender(bad)


@pytest.mark.asyncio
async def test_recording_sender_captures_requests():
    sender = RecordingSender()
    request = build_apns_request(
        device_token="deadbeef" * 8,
        bundle_id="org.ntust.app.TigerDuck",
        scenario=SCENARIO_CLASS_PREPARING,
        source_id="slot-777",
        fire_at=datetime(2026, 4, 22, 3, 0, tzinfo=timezone.utc),
        snapshot={
            "title": "Algorithms",
            "subtitle": "10:10-12:00",
            "locationText": "T2-401",
            "sourceId": "slot-777",
        },
        now=datetime(2026, 4, 22, 2, 45, tzinfo=timezone.utc),
    )
    result = await sender.send(request)
    assert result.success is True
    assert sender.requests == [request]
