"""aioapns wrapper — JWT auth + Live Activity Push-to-Start send path.

Uses the modern token-based auth (.p8 key + key_id + team_id). Same key works
for development and production; `use_sandbox` picks the APNs host.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import structlog
from aioapns import APNs, NotificationRequest, PushType

from server.config import Settings
from server.push.payload import ApnsRequest

logger = structlog.get_logger(__name__)


@dataclass(frozen=True)
class SendResult:
    success: bool
    status: str
    description: str | None = None
    notification_id: str | None = None


class PushSender(Protocol):
    async def send(self, request: ApnsRequest) -> SendResult: ...
    async def close(self) -> None: ...


class AioApnsSender:
    """Real APNs sender — requires p8 key file, key_id, team_id."""

    def __init__(self, settings: Settings) -> None:
        if not settings.apns_key_id or not settings.apns_team_id:
            raise ValueError(
                "APNs not configured: set TIGERDUCK_APNS_KEY_ID and _APNS_TEAM_ID"
            )
        key_path: Path = settings.apns_key_path
        if not key_path.exists():
            raise FileNotFoundError(f"APNs auth key not found: {key_path}")

        self._client = APNs(
            key=str(key_path),
            key_id=settings.apns_key_id,
            team_id=settings.apns_team_id,
            # per-request topic overrides this default
            topic=settings.apns_bundle_id,
            use_sandbox=settings.apns_env == "development",
        )

    async def send(self, request: ApnsRequest) -> SendResult:
        notification = NotificationRequest(
            device_token=request.device_token,
            message=request.message,
            priority=request.priority,
            time_to_live=max(0, request.expiration - _now_seconds()),
            push_type=PushType.LIVEACTIVITY,
            apns_topic=request.topic,
        )
        result = await self._client.send_notification(notification)
        return SendResult(
            success=result.is_successful,
            status=result.status,
            description=result.description,
            notification_id=result.notification_id,
        )

    async def close(self) -> None:
        # aioapns APNs has no public close; connections GC when client dereferenced.
        pass


class RecordingSender:
    """Test double — captures requests instead of hitting Apple.

    Use in unit tests and in the `TIGERDUCK_APNS_KEY_ID=''` dev path to avoid
    sending accidental pushes during local iteration.
    """

    def __init__(self) -> None:
        self.requests: list[ApnsRequest] = []

    async def send(self, request: ApnsRequest) -> SendResult:
        self.requests.append(request)
        logger.info(
            "apns.recorded",
            topic=request.topic,
            priority=request.priority,
            token_head=request.device_token[:8],
            expiration=request.expiration,
            aps_event=request.message["aps"].get("event"),
        )
        return SendResult(success=True, status="200", description="recorded")

    async def close(self) -> None:
        pass


def build_sender(settings: Settings) -> PushSender:
    """Return the real sender when APNs credentials exist, else a recording stub."""
    if settings.apns_key_id and settings.apns_team_id and settings.apns_key_path.exists():
        logger.info("apns.using_real_sender", env=settings.apns_env)
        return AioApnsSender(settings)
    logger.warning(
        "apns.using_recording_sender",
        reason="APNs credentials missing; pushes will not be delivered",
    )
    return RecordingSender()


def _now_seconds() -> int:
    from datetime import datetime, timezone

    return int(datetime.now(timezone.utc).timestamp())
