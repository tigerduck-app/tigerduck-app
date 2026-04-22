"""Dispatcher tests — uses RecordingSender so nothing hits APNs."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker

from server.config import Settings
from server.db import build_session_factory
from server.models import DeviceRegistration, PushStatus, ScheduledPush, build_push_id
from server.push.apns_client import RecordingSender, SendResult
from server.scheduler.dispatcher import dispatch_due_pushes

pytestmark = pytest.mark.asyncio(loop_scope="session")


DEVICE_ID = "dev-dispatcher"


async def _register_device(client: AsyncClient) -> None:
    resp = await client.post(
        "/v1/devices/register",
        json={
            "user_id": "user-dispatcher",
            "device_id": DEVICE_ID,
            "pts_token_hex": "aa" * 80,
            "device_token_hex": "bb" * 32,
            "apns_env": "development",
        },
    )
    assert resp.status_code == 200, resp.text


async def _seed_push(
    factory: async_sessionmaker,
    *,
    source_id: str,
    scenario: str,
    fire_at: datetime,
    status: str = PushStatus.pending.value,
    attempts: int = 0,
) -> str:
    push_id = build_push_id(DEVICE_ID, source_id, scenario)
    async with factory() as s:
        push = ScheduledPush(
            push_id=push_id,
            device_id=DEVICE_ID,
            source_id=source_id,
            scenario=scenario,
            fire_at=fire_at,
            payload_json={
                "scenario": scenario,
                "title": "Algorithms",
                "subtitle": "10:10-12:00",
                "locationText": "T2-401",
                "instructor": "王小明",
                "countdownTarget": fire_at.isoformat(),
                "progressStart": None,
                "accentHex": 0x4A90E2,
                "deepLink": None,
                "sourceId": source_id,
            },
            status=status,
            attempts=attempts,
        )
        s.add(push)
        await s.commit()
    return push_id


async def _status_of(factory: async_sessionmaker, push_id: str) -> tuple[str, int, str | None]:
    async with factory() as s:
        row = await s.get(ScheduledPush, push_id)
        assert row is not None
        return row.status, row.attempts, row.last_error


async def test_due_push_is_sent(client: AsyncClient, prepared_engine: AsyncEngine, test_settings: Settings):
    await _register_device(client)
    factory = build_session_factory(prepared_engine)

    now = datetime.now(timezone.utc)
    push_id = await _seed_push(
        factory,
        source_id="slot-a",
        scenario="classPreparing",
        fire_at=now,  # due right now
    )

    sender = RecordingSender()
    outcome = await dispatch_due_pushes(factory, sender, test_settings, now=now)

    assert outcome.dispatched == 1
    assert outcome.sent == 1
    assert len(sender.requests) == 1

    # Verify the payload is built with the Live Activity topic + PTS token
    req = sender.requests[0]
    assert req.topic.endswith(".push-type.liveactivity")
    assert req.priority == 10
    assert req.message["aps"]["event"] == "start"

    status, attempts, err = await _status_of(factory, push_id)
    assert status == PushStatus.sent.value
    assert attempts == 1
    assert err is None


async def test_future_push_is_skipped(client: AsyncClient, prepared_engine: AsyncEngine, test_settings: Settings):
    await _register_device(client)
    factory = build_session_factory(prepared_engine)
    now = datetime.now(timezone.utc)
    # Push far beyond the window (scheduler_window_seconds defaults to 60s)
    push_id = await _seed_push(
        factory,
        source_id="slot-future",
        scenario="classPreparing",
        fire_at=now + timedelta(minutes=10),
    )

    sender = RecordingSender()
    outcome = await dispatch_due_pushes(factory, sender, test_settings, now=now)

    assert outcome.dispatched == 0
    assert len(sender.requests) == 0

    status, _, _ = await _status_of(factory, push_id)
    assert status == PushStatus.pending.value


class _FailingSender:
    """Sender that always returns transient failures."""

    async def send(self, request) -> SendResult:
        return SendResult(success=False, status="500", description="simulated")

    async def close(self) -> None:
        pass


class _BadTokenSender:
    async def send(self, request) -> SendResult:
        return SendResult(success=False, status="410", description="BadDeviceToken")

    async def close(self) -> None:
        pass


async def test_transient_failure_bumps_attempts_then_fails(
    client: AsyncClient, prepared_engine: AsyncEngine, test_settings: Settings
):
    await _register_device(client)
    factory = build_session_factory(prepared_engine)
    now = datetime.now(timezone.utc)
    push_id = await _seed_push(
        factory, source_id="slot-retry", scenario="classPreparing", fire_at=now
    )

    sender = _FailingSender()

    # Tick 1 → attempts = 1, still pending
    await dispatch_due_pushes(factory, sender, test_settings, now=now)
    status, attempts, err = await _status_of(factory, push_id)
    assert status == PushStatus.pending.value
    assert attempts == 1
    assert "simulated" in (err or "")

    # Tick 2 → attempts = 2, still pending
    await dispatch_due_pushes(factory, sender, test_settings, now=now)
    status, attempts, _ = await _status_of(factory, push_id)
    assert status == PushStatus.pending.value
    assert attempts == 2

    # Tick 3 → attempts = 3 → marked failed
    await dispatch_due_pushes(factory, sender, test_settings, now=now)
    status, attempts, _ = await _status_of(factory, push_id)
    assert status == PushStatus.failed.value
    assert attempts == 3


async def test_expired_event_is_cancelled_not_sent(
    client: AsyncClient, prepared_engine: AsyncEngine, test_settings: Settings
):
    """Fix #5: if the snapshot's countdownTarget is already past, don't waste
    an APNs call — APNs would drop it anyway (apns-expiration=countdownTarget).
    Mark as cancelled so monitoring counts it correctly."""
    await _register_device(client)
    factory = build_session_factory(prepared_engine)

    now = datetime.now(timezone.utc)
    past = now - timedelta(minutes=30)
    push_id = build_push_id(DEVICE_ID, "slot-past", "inClass")

    # Seed a push whose countdownTarget is already 30 min in the past
    async with factory() as s:
        push = ScheduledPush(
            push_id=push_id,
            device_id=DEVICE_ID,
            source_id="slot-past",
            scenario="inClass",
            fire_at=now,  # fire_at due
            payload_json={
                "scenario": "inClass",
                "title": "Stale",
                "subtitle": "09:10-10:00",
                "sourceId": "slot-past",
                "countdownTarget": past.isoformat(),
            },
            status=PushStatus.pending.value,
            attempts=0,
        )
        s.add(push)
        await s.commit()

    sender = RecordingSender()
    outcome = await dispatch_due_pushes(factory, sender, test_settings, now=now)

    assert outcome.cancelled == 1
    assert outcome.sent == 0
    # No APNs call should have happened
    assert sender.requests == []

    status, _, err = await _status_of(factory, push_id)
    assert status == PushStatus.cancelled.value
    assert "event_expired" in (err or "")


async def test_bad_token_prunes_device_and_cancels(
    client: AsyncClient, prepared_engine: AsyncEngine, test_settings: Settings
):
    await _register_device(client)
    factory = build_session_factory(prepared_engine)
    now = datetime.now(timezone.utc)
    push_id = await _seed_push(
        factory, source_id="slot-bad", scenario="classPreparing", fire_at=now
    )

    sender = _BadTokenSender()
    outcome = await dispatch_due_pushes(factory, sender, test_settings, now=now)

    assert outcome.cancelled == 1

    # The FK ON DELETE CASCADE means pruning the device also removes its
    # queued pushes. Both the device and the push row should be gone.
    async with factory() as s:
        dev = await s.get(DeviceRegistration, DEVICE_ID)
        assert dev is None
        push = await s.get(ScheduledPush, push_id)
        assert push is None
