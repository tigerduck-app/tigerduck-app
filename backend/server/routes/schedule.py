"""Schedule sync endpoints — client is authoritative for next-48h events."""

from __future__ import annotations

import structlog
from fastapi import APIRouter, Depends, HTTPException, Path, status
from sqlalchemy import and_, delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from server.db import SessionDep
from server.models import DeviceRegistration, PushStatus, ScheduledPush, build_push_id
from server.schemas import (
    ScheduleDeleteResponse,
    ScheduleSyncRequest,
    ScheduleSyncResponse,
)
from server.security import require_shared_secret

router = APIRouter(
    prefix="/schedule",
    tags=["schedule"],
    dependencies=[Depends(require_shared_secret)],
)
logger = structlog.get_logger(__name__)


@router.post("/sync", response_model=ScheduleSyncResponse)
async def sync_schedule(
    payload: ScheduleSyncRequest,
    session: SessionDep,
) -> ScheduleSyncResponse:
    """Full replacement of pending pushes for this device.

    Steps:
    1. Verify device is registered.
    2. UPSERT every incoming event (keyed by push_id).
    3. DELETE pending pushes for this device whose push_id is NOT in payload.
    4. Return counts so the client can confirm.
    """
    device = await session.get(DeviceRegistration, payload.device_id)
    if device is None:
        raise HTTPException(status_code=404, detail="device not registered")

    incoming_push_ids: set[str] = set()
    upserted = 0
    for event in payload.events:
        push_id = build_push_id(
            device_id=payload.device_id,
            source_id=event.source_id,
            scenario=event.scenario.value,
        )
        incoming_push_ids.add(push_id)

        insert_stmt = pg_insert(ScheduledPush).values(
            push_id=push_id,
            device_id=payload.device_id,
            source_id=event.source_id,
            scenario=event.scenario.value,
            fire_at=event.fire_at,
            payload_json=event.snapshot,
            status=PushStatus.pending.value,
            attempts=0,
            last_error=None,
        )
        # Fix for duplicate-delivery bug (audit finding N2): only UPDATE rows
        # that have NOT already been delivered. A successful `sent` row means
        # the user's phone already got that notification — blindly resetting
        # to `pending` would re-fire on the next tick. The `where` clause
        # leaves sent rows completely untouched, so client re-syncs after a
        # delivery are idempotent.
        stmt = insert_stmt.on_conflict_do_update(
            index_elements=[ScheduledPush.push_id],
            set_={
                "fire_at": event.fire_at,
                "payload_json": event.snapshot,
                "status": PushStatus.pending.value,
                "attempts": 0,
                "last_error": None,
            },
            where=ScheduledPush.status != PushStatus.sent.value,
        )
        result = await session.execute(stmt)
        # rowcount is 0 when the ON CONFLICT WHERE clause suppresses the
        # update (row was already `sent`). Counting only real writes keeps
        # `scheduled` honest for observability.
        upserted += result.rowcount or 0

    # Cancel any pending pushes for this device that weren't in the sync.
    # Don't touch already-sent ones (history preservation).
    cancel_where = [
        ScheduledPush.device_id == payload.device_id,
        ScheduledPush.status == PushStatus.pending.value,
    ]
    if incoming_push_ids:
        cancel_where.append(ScheduledPush.push_id.notin_(incoming_push_ids))
    cancel_stmt = delete(ScheduledPush).where(and_(*cancel_where))
    cancel_result = await session.execute(cancel_stmt)
    cancelled = cancel_result.rowcount or 0

    # Final pending count for this device — server-side COUNT so we don't
    # materialise every ORM row just to call len() on it.
    count_result = await session.execute(
        select(func.count())
        .select_from(ScheduledPush)
        .where(
            and_(
                ScheduledPush.device_id == payload.device_id,
                ScheduledPush.status == PushStatus.pending.value,
            )
        )
    )
    total_pending = count_result.scalar_one()

    logger.info(
        "schedule.synced",
        device_id=payload.device_id,
        scheduled=upserted,
        cancelled=cancelled,
        total_pending=total_pending,
    )
    return ScheduleSyncResponse(
        device_id=payload.device_id,
        scheduled=upserted,
        cancelled=cancelled,
        total_pending=total_pending,
    )


@router.delete(
    "/{device_id}/{source_id}",
    response_model=ScheduleDeleteResponse,
    status_code=status.HTTP_200_OK,
)
async def cancel_by_source(
    session: SessionDep,
    device_id: str = Path(min_length=1, max_length=128),
    # Same `^[^:]+$` guard as ScheduleEvent.source_id — see that schema for
    # rationale (push_id collision prevention).
    source_id: str = Path(min_length=1, max_length=128, pattern=r"^[^:]+$"),
) -> ScheduleDeleteResponse:
    """Cancel every pending push for this device+source_id (all scenarios).

    Called when user completes an assignment or skips a course — removes all
    three potential pushes (classPreparing / inClass / assignmentUrgent).
    """
    stmt = delete(ScheduledPush).where(
        and_(
            ScheduledPush.device_id == device_id,
            ScheduledPush.source_id == source_id,
            ScheduledPush.status == PushStatus.pending.value,
        )
    )
    result = await session.execute(stmt)
    deleted = result.rowcount or 0
    logger.info(
        "schedule.cancelled",
        device_id=device_id,
        source_id=source_id,
        deleted=deleted,
    )
    return ScheduleDeleteResponse(
        device_id=device_id,
        source_id=source_id,
        deleted=deleted,
    )
