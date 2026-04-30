"""firebase-admin wrapper — service-account auth + alert send path.

Mirrors `apns_client.py` so the dispatcher / router code can treat both
platforms with the same `PushSender` protocol. firebase-admin's `messaging`
API is sync, so `send` is dispatched to a thread to avoid blocking the
asyncio loop.
"""

from __future__ import annotations

import asyncio
from datetime import timedelta
from pathlib import Path

import structlog

from server.push.apns_client import SendResult
from server.push.payload import FcmRequest

logger = structlog.get_logger(__name__)


class FcmSender:
    """Real FCM sender — requires a Firebase service-account JSON file."""

    def __init__(self, credentials_path: Path, project_id: str) -> None:
        # Import lazily so test envs without firebase-admin installed can
        # still import this module to grab `RecordingFcmSender`.
        import firebase_admin
        from firebase_admin import credentials

        cred = credentials.Certificate(str(credentials_path))
        # Named app so we don't collide with any other firebase_admin
        # initialization that might happen elsewhere in the process.
        self._app = firebase_admin.initialize_app(
            cred,
            name="tigerduck-fcm",
            options={"projectId": project_id},
        )

    async def send(self, request: FcmRequest) -> SendResult:
        import firebase_admin
        from firebase_admin import messaging

        msg = messaging.Message(
            token=request.token,
            notification=messaging.Notification(
                title=request.title, body=request.body
            ),
            data=request.data,
            android=messaging.AndroidConfig(
                priority="high",
                ttl=timedelta(seconds=request.ttl_seconds),
                notification=messaging.AndroidNotification(channel_id="bulletins"),
            ),
        )
        try:
            msg_id = await asyncio.to_thread(messaging.send, msg, app=self._app)
            return SendResult(
                success=True, status="200", description=msg_id
            )
        except messaging.UnregisteredError as e:
            return SendResult(
                success=False, status="UNREGISTERED", description=str(e)
            )
        except messaging.SenderIdMismatchError as e:
            return SendResult(
                success=False, status="SENDER_ID_MISMATCH", description=str(e)
            )
        except firebase_admin.exceptions.InvalidArgumentError as e:
            return SendResult(
                success=False, status="INVALID_ARGUMENT", description=str(e)
            )
        except (messaging.QuotaExceededError, messaging.ThirdPartyAuthError) as e:
            return SendResult(
                success=False, status="TRANSIENT", description=str(e)
            )
        except Exception as e:  # noqa: BLE001 — last-ditch catch mirrors APNs client
            return SendResult(
                success=False, status="UNKNOWN", description=str(e)
            )

    async def close(self) -> None:
        import firebase_admin

        firebase_admin.delete_app(self._app)


class RecordingFcmSender:
    """Test/dev double — captures requests instead of hitting Google.

    Mirrors `RecordingSender` for APNs so a backend running without
    Firebase service-account creds still presents the same interface to
    the dispatcher.
    """

    def __init__(self) -> None:
        self.requests: list[FcmRequest] = []

    async def send(self, request: FcmRequest) -> SendResult:
        self.requests.append(request)
        logger.info(
            "fcm.recorded",
            token_head=request.token[:8],
            ttl=request.ttl_seconds,
            data_keys=sorted(request.data.keys()),
        )
        return SendResult(success=True, status="200", description="recorded")

    async def close(self) -> None:
        pass
