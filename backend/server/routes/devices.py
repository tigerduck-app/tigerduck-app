"""Device registration endpoints."""

from __future__ import annotations

import structlog
from fastapi import APIRouter, Depends, status
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from server.db import SessionDep
from server.models import DeviceRegistration
from server.schemas import (
    DeviceRegisterRequest,
    DeviceRegisterResponse,
    DeviceUnregisterRequest,
)
from server.security import require_shared_secret

router = APIRouter(
    prefix="/devices",
    tags=["devices"],
    dependencies=[Depends(require_shared_secret)],
)
logger = structlog.get_logger(__name__)


@router.post("/register", response_model=DeviceRegisterResponse)
async def register_device(
    payload: DeviceRegisterRequest,
    session: SessionDep,
) -> DeviceRegisterResponse:
    """Upsert a device registration. Idempotent — called on every app launch."""
    stmt = (
        pg_insert(DeviceRegistration)
        .values(
            device_id=payload.device_id,
            user_id=payload.user_id,
            pts_token_hex=payload.pts_token_hex,
            device_token_hex=payload.device_token_hex,
            bundle_id=payload.bundle_id,
            attrs_type=payload.attrs_type,
            apns_env=payload.apns_env,
        )
        .on_conflict_do_update(
            index_elements=[DeviceRegistration.device_id],
            set_={
                "user_id": payload.user_id,
                "pts_token_hex": payload.pts_token_hex,
                "device_token_hex": payload.device_token_hex,
                "bundle_id": payload.bundle_id,
                "attrs_type": payload.attrs_type,
                "apns_env": payload.apns_env,
                "updated_at": func.now(),
            },
        )
        .returning(DeviceRegistration)
    )
    result = await session.execute(stmt)
    device = result.scalar_one()

    logger.info(
        "device.registered",
        device_id=device.device_id,
        user_id=device.user_id,
        apns_env=device.apns_env,
    )
    return DeviceRegisterResponse(
        device_id=device.device_id,
        user_id=device.user_id,
        registered_at=device.updated_at,
    )


@router.post("/unregister", status_code=status.HTTP_204_NO_CONTENT)
async def unregister_device(
    payload: DeviceUnregisterRequest,
    session: SessionDep,
) -> None:
    """Delete the device and cascade-delete its pending pushes."""
    stmt = delete(DeviceRegistration).where(
        DeviceRegistration.device_id == payload.device_id
    )
    await session.execute(stmt)
    logger.info("device.unregistered", device_id=payload.device_id)


@router.get("/{device_id}", response_model=DeviceRegisterResponse)
async def get_device(device_id: str, session: SessionDep) -> DeviceRegisterResponse:
    """Read back a device registration (used by tests and /debug tooling)."""
    result = await session.execute(
        select(DeviceRegistration).where(DeviceRegistration.device_id == device_id)
    )
    device = result.scalar_one_or_none()
    if device is None:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="device not found")
    return DeviceRegisterResponse(
        device_id=device.device_id,
        user_id=device.user_id,
        registered_at=device.updated_at,
    )
