"""Debug endpoints — gated behind TIGERDUCK_ENV != production.

Lets us verify the dispatcher path end-to-end without waiting for a real
fire_at to elapse. Production builds should set TIGERDUCK_ENV=production
to hide these.
"""

from __future__ import annotations

from datetime import datetime, timezone

import structlog
from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select

from server.db import SessionDep
from server.models import DeviceRegistration, PushStatus, ScheduledPush
from server.push.payload import build_apns_request
from server.scheduler.dispatcher import dispatch_due_pushes
from server.security import require_shared_secret

router = APIRouter(
    prefix="/_debug",
    tags=["debug"],
    dependencies=[Depends(require_shared_secret)],
)
logger = structlog.get_logger(__name__)


def _require_dev(request: Request) -> None:
    if request.app.state.settings.env == "production":
        raise HTTPException(status_code=404, detail="not found")


@router.get("/stats")
async def stats(request: Request, session: SessionDep) -> dict:
    _require_dev(request)
    from sqlalchemy import func

    rows = await session.execute(
        select(ScheduledPush.status, func.count()).group_by(ScheduledPush.status)
    )
    by_status = dict(rows.all())
    device_count = (await session.execute(select(func.count()).select_from(DeviceRegistration))).scalar_one()
    return {
        "devices": device_count,
        "pushes_by_status": by_status,
        "sender_type": type(request.app.state.sender).__name__,
    }


@router.post("/tick")
async def force_tick(request: Request) -> dict:
    """Run one dispatcher tick immediately instead of waiting for the timer."""
    _require_dev(request)
    outcome = await dispatch_due_pushes(
        session_factory=request.app.state.session_factory,
        sender=request.app.state.sender,
        settings=request.app.state.settings,
    )
    return {
        "dispatched": outcome.dispatched,
        "sent": outcome.sent,
        "failed": outcome.failed,
        "cancelled": outcome.cancelled,
    }


@router.post("/fire/{push_id:path}")
async def fire_one(
    push_id: str,
    request: Request,
    session: SessionDep,
) -> dict:
    """Send one specific push_id now, bypassing fire_at. Status unchanged.
    For smoke-testing APNs delivery without waiting for scheduled time."""
    _require_dev(request)
    push = await session.get(ScheduledPush, push_id)
    if push is None:
        raise HTTPException(status_code=404, detail=f"no such push_id: {push_id}")
    device = await session.get(DeviceRegistration, push.device_id)
    if device is None:
        raise HTTPException(status_code=404, detail="device missing")

    req = build_apns_request(
        device_token=device.pts_token_hex,
        bundle_id=device.bundle_id,
        scenario=push.scenario,
        source_id=push.source_id,
        fire_at=push.fire_at,
        snapshot=push.payload_json,
        attrs_type=device.attrs_type,
        now=datetime.now(timezone.utc),
    )
    sender = request.app.state.sender
    result = await sender.send(req)
    logger.info(
        "debug.fire",
        push_id=push_id,
        success=result.success,
        status=result.status,
        desc=result.description,
    )
    return {
        "push_id": push_id,
        "apns_status": result.status,
        "success": result.success,
        "description": result.description,
    }


@router.post("/fire_first_pending")
async def fire_first_pending(
    request: Request,
    session: SessionDep,
) -> dict:
    """Grab the earliest-scheduled pending push and fire it now."""
    _require_dev(request)
    row = await session.execute(
        select(ScheduledPush)
        .where(ScheduledPush.status == PushStatus.pending.value)
        .order_by(ScheduledPush.fire_at.asc())
        .limit(1)
    )
    push = row.scalar_one_or_none()
    if push is None:
        raise HTTPException(status_code=404, detail="no pending pushes")

    device = await session.get(DeviceRegistration, push.device_id)
    if device is None:
        raise HTTPException(status_code=404, detail="device missing for push")

    req = build_apns_request(
        device_token=device.pts_token_hex,
        bundle_id=device.bundle_id,
        scenario=push.scenario,
        source_id=push.source_id,
        fire_at=push.fire_at,
        snapshot=push.payload_json,
        attrs_type=device.attrs_type,
        now=datetime.now(timezone.utc),
    )
    sender = request.app.state.sender
    result = await sender.send(req)
    logger.info(
        "debug.fire_first",
        push_id=push.push_id,
        scenario=push.scenario,
        success=result.success,
        status=result.status,
        desc=result.description,
    )
    return {
        "push_id": push.push_id,
        "scenario": push.scenario,
        "title": push.payload_json.get("title"),
        "apns_status": result.status,
        "success": result.success,
        "description": result.description,
    }
