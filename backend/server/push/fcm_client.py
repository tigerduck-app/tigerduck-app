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

    def __init__(
        self,
        credentials_path: Path,
        project_id: str,
        send_timeout_seconds: float = 15.0,
    ) -> None:
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
        self._send_timeout = send_timeout_seconds

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
            msg_id = await asyncio.wait_for(
                asyncio.to_thread(messaging.send, msg, app=self._app),
                timeout=self._send_timeout,
            )
            return SendResult(
                success=True, status="200", description=msg_id
            )
        except asyncio.TimeoutError:
            # The to_thread worker is still running underneath us; we've just
            # detached. That's intentional — better to leak a daemon thread
            # than to keep the dispatcher tick blocked forever.
            return SendResult(
                success=False,
                status="TIMEOUT",
                description=f"FCM send exceeded {self._send_timeout}s",
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

    async def send_multi(self, requests: list[FcmRequest]) -> list[SendResult]:
        """Fan one bulletin out to many devices in a single batched RPC.

        firebase-admin's `messaging.send` opens a fresh TLS connection per
        call, which scales linearly in the number of subscribers. For the
        bulletin path every request in a batch shares title/body/data and
        only differs by token, so `send_each_for_multicast` collapses the
        whole fan-out into ~ceil(N/500) round trips with internal
        thread-pool concurrency. Returns one SendResult per input request,
        in the same order.

        Empty input is a no-op (no RPC). All requests in `requests` MUST
        share the same title/body/data/ttl — caller's responsibility (the
        bulletin dispatcher already builds one per-(bulletin,device) but
        every (bulletin,*) tuple has identical content).
        """
        import firebase_admin
        from firebase_admin import messaging

        if not requests:
            return []

        first = requests[0]
        results: list[SendResult] = []
        # Google caps `send_each_for_multicast` at 500 tokens per call.
        chunk_size = 500
        for start in range(0, len(requests), chunk_size):
            chunk = requests[start : start + chunk_size]
            msg = messaging.MulticastMessage(
                tokens=[r.token for r in chunk],
                notification=messaging.Notification(
                    title=first.title, body=first.body
                ),
                data=first.data,
                android=messaging.AndroidConfig(
                    priority="high",
                    ttl=timedelta(seconds=first.ttl_seconds),
                    notification=messaging.AndroidNotification(channel_id="bulletins"),
                ),
            )
            try:
                batch = await asyncio.wait_for(
                    asyncio.to_thread(
                        messaging.send_each_for_multicast, msg, app=self._app
                    ),
                    timeout=self._send_timeout,
                )
            except asyncio.TimeoutError:
                # Same detach-and-move-on contract as `send`. One stuck
                # batch can't wedge the whole dispatcher tick.
                results.extend(
                    SendResult(
                        success=False,
                        status="TIMEOUT",
                        description=f"FCM batch exceeded {self._send_timeout}s",
                    )
                    for _ in chunk
                )
                continue

            for resp in batch.responses:
                results.append(_classify_batch_response(resp, firebase_admin, messaging))
        return results

    async def close(self) -> None:
        import firebase_admin

        firebase_admin.delete_app(self._app)


def _classify_batch_response(resp, firebase_admin, messaging) -> SendResult:
    """Map one `messaging.SendResponse` to our SendResult shape.

    Mirrors the per-exception classification in `FcmSender.send` so a
    multicast call surfaces bad_token / transient / unknown the same way
    the dispatcher already understands.
    """
    if resp.success:
        return SendResult(success=True, status="200", description=resp.message_id)
    exc = resp.exception
    if isinstance(exc, messaging.UnregisteredError):
        return SendResult(success=False, status="UNREGISTERED", description=str(exc))
    if isinstance(exc, messaging.SenderIdMismatchError):
        return SendResult(
            success=False, status="SENDER_ID_MISMATCH", description=str(exc)
        )
    if isinstance(exc, firebase_admin.exceptions.InvalidArgumentError):
        return SendResult(
            success=False, status="INVALID_ARGUMENT", description=str(exc)
        )
    if isinstance(exc, (messaging.QuotaExceededError, messaging.ThirdPartyAuthError)):
        return SendResult(success=False, status="TRANSIENT", description=str(exc))
    return SendResult(success=False, status="UNKNOWN", description=str(exc))


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

    async def send_multi(self, requests: list[FcmRequest]) -> list[SendResult]:
        return [await self.send(r) for r in requests]

    async def close(self) -> None:
        pass
