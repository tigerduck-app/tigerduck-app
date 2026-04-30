"""Platform-aware push router.

Wraps the APNs and FCM senders behind one object so the dispatcher /
scheduler can branch on `device.platform` without importing either SDK
directly. Each sender is a `PushSender`-shaped duck (async `send`,
async `close`); the router does not interpret the request payloads, it
just hands them to the right channel.
"""

from __future__ import annotations

import structlog

from server.config import Settings
from server.push.apns_client import PushSender, SendResult, build_sender
from server.push.payload import ApnsRequest, FcmRequest

logger = structlog.get_logger(__name__)


class PushRouter:
    def __init__(self, *, apple: PushSender, android: PushSender) -> None:
        self._apple = apple
        self._android = android

    @property
    def apple(self) -> PushSender:
        """Expose the APNs sender directly for paths that don't need the
        platform branch (Live Activities, scheduled iOS pushes)."""
        return self._apple

    async def send_apple(self, request: ApnsRequest) -> SendResult:
        return await self._apple.send(request)

    async def send_android(self, request: FcmRequest) -> SendResult:
        return await self._android.send(request)

    async def close(self) -> None:
        try:
            await self._apple.close()
        finally:
            await self._android.close()


def build_router(settings: Settings) -> PushRouter:
    """Construct a router with real or recording senders based on settings.

    Apple side is delegated to `build_sender` so the same APNs cred check
    keeps working. Android side spins up `FcmSender` only when both the
    project id and credentials file are present, otherwise falls back to
    `RecordingFcmSender` — mirrors the APNs dev-fallback behavior so a
    laptop without Firebase creds can still boot the server.
    """
    apple = build_sender(settings)
    if settings.fcm_project_id and settings.fcm_credentials_path.exists():
        from server.push.fcm_client import FcmSender

        logger.info("fcm.using_real_sender", project_id=settings.fcm_project_id)
        android = FcmSender(settings.fcm_credentials_path, settings.fcm_project_id)
    else:
        from server.push.fcm_client import RecordingFcmSender

        logger.warning(
            "fcm.using_recording_sender",
            reason="FCM credentials missing; android pushes will not be delivered",
        )
        android = RecordingFcmSender()
    return PushRouter(apple=apple, android=android)
