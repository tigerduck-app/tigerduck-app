"""Pydantic request/response models for the HTTP API."""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Any

from pydantic import BaseModel, Field


class ScenarioKind(StrEnum):
    class_preparing = "classPreparing"
    in_class = "inClass"
    assignment_urgent = "assignmentUrgent"


class DeviceRegisterRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=64)
    device_id: str = Field(min_length=1, max_length=128)
    # 'apple' (APNs, pts_token_hex = Push-to-Start token) or 'android' (FCM,
    # pts_token_hex = FCM registration token). Defaults to apple so existing
    # iOS clients that haven't been rebuilt keep working.
    platform: str = Field(default="apple", pattern="^(apple|android)$")
    pts_token_hex: str = Field(min_length=1, max_length=512)
    device_token_hex: str | None = Field(default=None, max_length=512)
    bundle_id: str = Field(default="org.ntust.app.TigerDuck", max_length=128)
    attrs_type: str = Field(default="TigerDuckActivityAttributes", max_length=128)
    apns_env: str = Field(default="development", pattern="^(development|production)$")


class DeviceRegisterResponse(BaseModel):
    device_id: str
    user_id: str
    platform: str
    registered_at: datetime


class DeviceUnregisterRequest(BaseModel):
    device_id: str = Field(min_length=1, max_length=128)


class ScheduleEvent(BaseModel):
    # `:` is reserved as the separator in build_push_id(device_id, source_id,
    # scenario). Allowing it in source_id would let two distinct (source_id,
    # scenario) pairs collide onto the same push_id and silently overwrite
    # each other (e.g. ("a:b", "x") vs. ("a", "b:x")).
    source_id: str = Field(min_length=1, max_length=128, pattern=r"^[^:]+$")
    scenario: ScenarioKind
    fire_at: datetime
    snapshot: dict[str, Any]


class ScheduleSyncRequest(BaseModel):
    device_id: str = Field(min_length=1, max_length=128)
    events: list[ScheduleEvent] = Field(default_factory=list, max_length=500)


class ScheduleSyncResponse(BaseModel):
    device_id: str
    scheduled: int
    cancelled: int
    total_pending: int


class ScheduleDeleteResponse(BaseModel):
    device_id: str
    source_id: str
    deleted: int
