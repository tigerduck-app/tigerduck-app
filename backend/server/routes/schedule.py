"""Schedule sync endpoints — client is authoritative for next-48h events."""

from __future__ import annotations

import structlog
from fastapi import APIRouter, HTTPException, status
from sqlalchemy import and_, delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from server.db import SessionDep
from server.models import DeviceRegistration, PushStatus, ScheduledPush, build_push_id
from server.schemas import (
    ScheduleDeleteResponse,
    ScheduleSyncRequest,
    ScheduleSyncResponse,
)

router = APIRouter(prefix="/schedule", tags=["schedule"])
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

        stmt = (
            pg_insert(ScheduledPush)
            .values(
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
            .on_conflict_do_update(
                index_elements=[ScheduledPush.push_id],
                set_={
                    "fire_at": event.fire_at,
                    "payload_json": event.snapshot,
                    # Re-queue if previously failed/cancelled: only reset to pending
                    # when fire_at is still in the future. Otherwise leave history.
                    "status": PushStatus.pending.value,
                    "attempts": 0,
                    "last_error": None,
                },
            )
        )
        await session.execute(stmt)
        upserted += 1

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

    # Final pending count for this device
    count_result = await session.execute(
        select(ScheduledPush).where(
            and_(
                ScheduledPush.device_id == payload.device_id,
                ScheduledPush.status == PushStatus.pending.value,
            )
        )
    )
    total_pending = len(count_result.scalars().all())

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
    device_id: str,
    source_id: str,
    session: SessionDep,
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
