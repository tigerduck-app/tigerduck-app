"""Schedule sync endpoint tests."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio(loop_scope="session")


DEVICE_ID = "device-sched"
USER_ID = "user-sched"


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat()


def _snapshot(title: str) -> dict:
    return {
        "scenario": "classPreparing",
        "title": title,
        "subtitle": "10:10-12:00",
        "locationText": "T2-401",
        "instructor": "王小明",
        "countdownTarget": _iso(datetime.now(timezone.utc) + timedelta(minutes=30)),
        "progressStart": None,
        "accentHex": 0x4A90E2,
        "deepLink": None,
        "sourceId": "slot-1",
    }


async def _register(client: AsyncClient) -> None:
    await client.post(
        "/v1/devices/register",
        json={
            "user_id": USER_ID,
            "device_id": DEVICE_ID,
            "pts_token_hex": "a" * 128,
            "apns_env": "development",
        },
    )


async def test_sync_requires_registered_device(client: AsyncClient):
    response = await client.post(
        "/v1/schedule/sync",
        json={"device_id": "never-registered", "events": []},
    )
    assert response.status_code == 404


async def test_sync_inserts_and_reports_counts(client: AsyncClient):
    await _register(client)
    fire = datetime.now(timezone.utc) + timedelta(minutes=15)
    response = await client.post(
        "/v1/schedule/sync",
        json={
            "device_id": DEVICE_ID,
            "events": [
                {
                    "source_id": "slot-1",
                    "scenario": "classPreparing",
                    "fire_at": _iso(fire),
                    "snapshot": _snapshot("Intro to CS"),
                },
                {
                    "source_id": "slot-1",
                    "scenario": "inClass",
                    "fire_at": _iso(fire + timedelta(minutes=15)),
                    "snapshot": _snapshot("Intro to CS"),
                },
            ],
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["scheduled"] == 2
    assert body["cancelled"] == 0
    assert body["total_pending"] == 2


async def test_sync_replaces_previous_events(client: AsyncClient):
    await _register(client)
    fire = datetime.now(timezone.utc) + timedelta(hours=1)

    first = await client.post(
        "/v1/schedule/sync",
        json={
            "device_id": DEVICE_ID,
            "events": [
                {
                    "source_id": "slot-1",
                    "scenario": "classPreparing",
                    "fire_at": _iso(fire),
                    "snapshot": _snapshot("A"),
                },
                {
                    "source_id": "slot-2",
                    "scenario": "classPreparing",
                    "fire_at": _iso(fire + timedelta(hours=2)),
                    "snapshot": _snapshot("B"),
                },
            ],
        },
    )
    assert first.json()["total_pending"] == 2

    # Second sync keeps only slot-2, so slot-1 should be cancelled
    second = await client.post(
        "/v1/schedule/sync",
        json={
            "device_id": DEVICE_ID,
            "events": [
                {
                    "source_id": "slot-2",
                    "scenario": "classPreparing",
                    "fire_at": _iso(fire + timedelta(hours=2)),
                    "snapshot": _snapshot("B"),
                },
            ],
        },
    )
    body = second.json()
    assert body["cancelled"] == 1
    assert body["total_pending"] == 1


async def test_cancel_by_source_removes_all_scenarios(client: AsyncClient):
    await _register(client)
    fire = datetime.now(timezone.utc) + timedelta(hours=2)

    await client.post(
        "/v1/schedule/sync",
        json={
            "device_id": DEVICE_ID,
            "events": [
                {
                    "source_id": "slot-1",
                    "scenario": "classPreparing",
                    "fire_at": _iso(fire),
                    "snapshot": _snapshot("A"),
                },
                {
                    "source_id": "slot-1",
                    "scenario": "inClass",
                    "fire_at": _iso(fire + timedelta(minutes=15)),
                    "snapshot": _snapshot("A"),
                },
                {
                    "source_id": "slot-2",
                    "scenario": "classPreparing",
                    "fire_at": _iso(fire + timedelta(hours=3)),
                    "snapshot": _snapshot("B"),
                },
            ],
        },
    )

    cancel = await client.delete(f"/v1/schedule/{DEVICE_ID}/slot-1")
    assert cancel.status_code == 200
    assert cancel.json()["deleted"] == 2

    # Now re-sync with empty to count remaining
    final = await client.post(
        "/v1/schedule/sync",
        json={
            "device_id": DEVICE_ID,
            "events": [
                {
                    "source_id": "slot-2",
                    "scenario": "classPreparing",
                    "fire_at": _iso(fire + timedelta(hours=3)),
                    "snapshot": _snapshot("B"),
                },
            ],
        },
    )
    assert final.json()["total_pending"] == 1
