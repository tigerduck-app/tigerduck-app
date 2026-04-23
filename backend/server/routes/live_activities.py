"""Live Activity update-token registration endpoints."""

from __future__ import annotations

import structlog
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func
from sqlalchemy.dialects.postgresql import insert as pg_insert

from server.db import SessionDep
from server.models import (
    DeviceRegistration,
    LiveActivityTokenStatus,
    LiveActivityUpdateToken,
)
from server.schemas import (
    LiveActivityTokenRegisterRequest,
    LiveActivityTokenRegisterResponse,
)
from server.security import require_shared_secret

router = APIRouter(
    prefix="/live-activities",
    tags=["live-activities"],
    dependencies=[Depends(require_shared_secret)],
)
logger = structlog.get_logger(__name__)


@router.post("/register", response_model=LiveActivityTokenRegisterResponse)
async def register_live_activity_token(
    payload: LiveActivityTokenRegisterRequest,
    session: SessionDep,
) -> LiveActivityTokenRegisterResponse:
    """Upsert the per-activity update token used for server-side end pushes."""
    device = await session.get(DeviceRegistration, payload.device_id)
    if device is None:
        raise HTTPException(status_code=404, detail="device not registered")

    stmt = (
        pg_insert(LiveActivityUpdateToken)
        .values(
            activity_id=payload.activity_id,
            device_id=payload.device_id,
            source_id=payload.source_id,
            scenario=payload.scenario.value,
            update_token_hex=payload.update_token_hex,
            countdown_target=payload.countdown_target,
            snapshot_json=payload.snapshot,
            status=LiveActivityTokenStatus.active.value,
            attempts=0,
            last_error=None,
            ended_at=None,
        )
        .on_conflict_do_update(
            index_elements=[LiveActivityUpdateToken.activity_id],
            set_={
                "device_id": payload.device_id,
                "source_id": payload.source_id,
                "scenario": payload.scenario.value,
                "update_token_hex": payload.update_token_hex,
                "countdown_target": payload.countdown_target,
                "snapshot_json": payload.snapshot,
                "status": LiveActivityTokenStatus.active.value,
                "attempts": 0,
                "last_error": None,
                "ended_at": None,
                "updated_at": func.now(),
            },
        )
        .returning(LiveActivityUpdateToken)
    )
    result = await session.execute(stmt)
    row = result.scalar_one()

    logger.info(
        "live_activity_token.registered",
        device_id=row.device_id,
        activity_id=row.activity_id,
        scenario=row.scenario,
        countdown_target=row.countdown_target,
    )
    return LiveActivityTokenRegisterResponse(
        device_id=row.device_id,
        activity_id=row.activity_id,
        registered_at=row.updated_at,
    )
