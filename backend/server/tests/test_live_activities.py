"""Live Activity update-token endpoint tests."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine

from server.db import build_session_factory
from server.models import LiveActivityTokenStatus, LiveActivityUpdateToken

pytestmark = pytest.mark.asyncio(loop_scope="session")


DEVICE_ID = "device-live-activity"


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat()


def _snapshot(countdown_target: datetime) -> dict:
    return {
        "scenario": "classPreparing",
        "title": "Algorithms",
        "subtitle": "10:10-12:00",
        "locationText": "T2-401",
        "instructor": "王小明",
        "countdownTarget": _iso(countdown_target),
        "progressStart": None,
        "accentHex": 0x4A90E2,
        "deepLink": None,
        "sourceId": "slot-live",
    }


async def _register_device(client: AsyncClient) -> None:
    response = await client.post(
        "/v1/devices/register",
        json={
            "user_id": "user-live",
            "device_id": DEVICE_ID,
            "pts_token_hex": "a" * 128,
            "apns_env": "development",
        },
    )
    assert response.status_code == 200, response.text


async def test_register_live_activity_token_requires_device(client: AsyncClient):
    target = datetime.now(timezone.utc) + timedelta(minutes=15)
    response = await client.post(
        "/v1/live-activities/register",
        json={
            "device_id": "missing-device",
            "activity_id": "classPreparing::slot-live",
            "source_id": "slot-live",
            "scenario": "classPreparing",
            "update_token_hex": "b" * 128,
            "countdown_target": _iso(target),
            "snapshot": _snapshot(target),
        },
    )
    assert response.status_code == 404


async def test_register_live_activity_token_upserts(
    client: AsyncClient,
    prepared_engine: AsyncEngine,
):
    await _register_device(client)
    target = datetime.now(timezone.utc) + timedelta(minutes=15)

    first = await client.post(
        "/v1/live-activities/register",
        json={
            "device_id": DEVICE_ID,
            "activity_id": "classPreparing::slot-live",
            "source_id": "slot-live",
            "scenario": "classPreparing",
            "update_token_hex": "b" * 128,
            "countdown_target": _iso(target),
            "snapshot": _snapshot(target),
        },
    )
    assert first.status_code == 200, first.text

    second_target = target + timedelta(minutes=5)
    second = await client.post(
        "/v1/live-activities/register",
        json={
            "device_id": DEVICE_ID,
            "activity_id": "classPreparing::slot-live",
            "source_id": "slot-live",
            "scenario": "classPreparing",
            "update_token_hex": "c" * 128,
            "countdown_target": _iso(second_target),
            "snapshot": _snapshot(second_target),
        },
    )
    assert second.status_code == 200, second.text

    factory = build_session_factory(prepared_engine)
    async with factory() as s:
        rows = (
            await s.execute(
                select(LiveActivityUpdateToken).where(
                    LiveActivityUpdateToken.device_id == DEVICE_ID
                )
            )
        ).scalars().all()
    assert len(rows) == 1
    assert rows[0].update_token_hex == "c" * 128
    assert rows[0].status == LiveActivityTokenStatus.active.value
