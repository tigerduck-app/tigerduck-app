"""Retention job tests — ended/failed/cancelled Live Activity tokens are
pruned past their retention window, active rows are untouched."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from httpx import AsyncClient
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncEngine

from server.config import Settings
from server.db import build_session_factory
from server.models import LiveActivityTokenStatus, LiveActivityUpdateToken
from server.scheduler.retention import prune_terminal_activity_tokens

pytestmark = pytest.mark.asyncio(loop_scope="session")


DEVICE_ID = "device-retention"


async def _register_device(client: AsyncClient) -> None:
    response = await client.post(
        "/v1/devices/register",
        json={
            "user_id": "user-retention",
            "device_id": DEVICE_ID,
            "pts_token_hex": "a" * 128,
            "apns_env": "development",
        },
    )
    assert response.status_code == 200, response.text


async def _seed_token(
    factory,
    *,
    activity_id: str,
    status: str,
    updated_delta: timedelta,
) -> None:
    now = datetime.now(timezone.utc)
    async with factory() as s:
        s.add(
            LiveActivityUpdateToken(
                activity_id=activity_id,
                device_id=DEVICE_ID,
                source_id=activity_id.split("::")[-1],
                scenario="inClass",
                update_token_hex="c" * 80,
                countdown_target=None,
                snapshot_json={"sourceId": activity_id.split("::")[-1]},
                status=status,
                attempts=1,
            )
        )
        await s.commit()
        # Tests can't rely on created_at/updated_at since SQLAlchemy stamps
        # them with NOW() at insert. Backdate explicitly so the cutoff logic
        # has something to match against.
        await s.execute(
            update(LiveActivityUpdateToken)
            .where(LiveActivityUpdateToken.activity_id == activity_id)
            .values(updated_at=now - updated_delta)
        )
        await s.commit()


async def test_retention_prunes_terminal_rows_past_cutoff(
    client: AsyncClient,
    prepared_engine: AsyncEngine,
    test_settings: Settings,
):
    await _register_device(client)
    factory = build_session_factory(prepared_engine)

    retention = timedelta(days=test_settings.live_activity_token_retention_days)
    await _seed_token(
        factory,
        activity_id="inClass::old-ended",
        status=LiveActivityTokenStatus.ended.value,
        updated_delta=retention + timedelta(days=1),
    )
    await _seed_token(
        factory,
        activity_id="inClass::old-cancelled",
        status=LiveActivityTokenStatus.cancelled.value,
        updated_delta=retention + timedelta(days=1),
    )
    await _seed_token(
        factory,
        activity_id="inClass::old-failed",
        status=LiveActivityTokenStatus.failed.value,
        updated_delta=retention + timedelta(days=1),
    )
    await _seed_token(
        factory,
        activity_id="inClass::recent-ended",
        status=LiveActivityTokenStatus.ended.value,
        updated_delta=timedelta(days=1),
    )
    await _seed_token(
        factory,
        activity_id="inClass::old-but-active",
        status=LiveActivityTokenStatus.active.value,
        updated_delta=retention + timedelta(days=1),
    )

    deleted = await prune_terminal_activity_tokens(factory, test_settings)
    assert deleted == 3

    async with factory() as s:
        rows = (
            await s.execute(
                select(LiveActivityUpdateToken.activity_id).order_by(
                    LiveActivityUpdateToken.activity_id
                )
            )
        ).scalars().all()
    assert rows == ["inClass::old-but-active", "inClass::recent-ended"]
