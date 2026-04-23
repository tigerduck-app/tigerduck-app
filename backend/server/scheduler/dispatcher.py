"""Scheduler tick that dispatches due pushes to APNs.

Runs every `scheduler_tick_seconds` (default 30s). Each tick:
1. SELECT pending pushes where `fire_at <= now + window`, FOR UPDATE SKIP LOCKED
2. Build the ApnsRequest from stored payload + device row's pts_token_hex
3. Send via the injected PushSender
4. On success: status=sent, sent_at=now
5. On 410 BadDeviceToken: status=cancelled, and delete the device row (iOS
   reinstall rotates the token, so the old device id is dead forever)
6. On transient failure: bump attempts; after `max_attempts` mark failed

The lock hint prevents two concurrent workers from double-sending the
same push. With APScheduler's `max_instances=1` this is belt-and-braces,
but we keep it in case we ever scale horizontally.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import structlog
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from server.config import Settings
from server.models import (
    DeviceRegistration,
    LiveActivityTokenStatus,
    LiveActivityUpdateToken,
    PushStatus,
    ScheduledPush,
)
from server.push.apns_client import PushSender, SendResult
from server.push.payload import (
    ApnsRequest,
    _countdown_target_unix,
    build_apns_request,
    build_live_activity_end_request,
)

logger = structlog.get_logger(__name__)

MAX_ATTEMPTS = 3


@dataclass(frozen=True)
class TickOutcome:
    dispatched: int
    sent: int
    failed: int
    cancelled: int


async def dispatch_due_pushes(
    session_factory: async_sessionmaker[AsyncSession],
    sender: PushSender,
    settings: Settings,
    *,
    now: datetime | None = None,
) -> TickOutcome:
    """One scheduler tick. Returns counts so callers can log or test."""
    ts = now or datetime.now(timezone.utc)
    window_end = ts + timedelta(seconds=settings.scheduler_window_seconds)

    sent = failed = cancelled = 0
    dispatched = 0

    async with session_factory() as session:
        # Lock the due rows so a parallel tick cannot grab the same ids.
        stmt = (
            select(ScheduledPush, DeviceRegistration)
            .join(DeviceRegistration, DeviceRegistration.device_id == ScheduledPush.device_id)
            .where(
                ScheduledPush.status == PushStatus.pending.value,
                ScheduledPush.fire_at <= window_end,
            )
            .with_for_update(skip_locked=True)
            .limit(64)
        )
        rows = (await session.execute(stmt)).all()

        # Once a device's token comes back as BadDeviceToken / Unregistered we
        # cascade-delete it. The locked `rows` list still holds the device's
        # other pending pushes in memory, so without this guard we'd keep
        # firing APNs requests at the same dead token and then no-op UPDATE
        # already-deleted rows.
        pruned_device_ids: set[str] = set()

        for push, device in rows:
            dispatched += 1

            if device.device_id in pruned_device_ids:
                continue

            # Fix #5: skip pushes whose underlying event moment has already
            # passed. Sending them would waste a round-trip on Apple that
            # APNs drops anyway (apns-expiration = countdownTarget). Mark
            # cancelled so monitoring counts them correctly.
            countdown_unix = _countdown_target_unix(push.payload_json)
            if countdown_unix is not None and countdown_unix < int(ts.timestamp()):
                await _mark_cancelled(
                    session,
                    push,
                    reason=f"event_expired countdownTarget={countdown_unix}",
                )
                cancelled += 1
                continue

            try:
                request = build_apns_request(
                    device_token=device.pts_token_hex,
                    bundle_id=device.bundle_id,
                    scenario=push.scenario,
                    source_id=push.source_id,
                    fire_at=push.fire_at,
                    snapshot=push.payload_json,
                    attrs_type=device.attrs_type,
                    now=ts,
                )
            except Exception as build_error:  # pragma: no cover — defensive
                await _mark_failed(session, push, reason=f"build_error: {build_error}")
                failed += 1
                logger.exception("dispatcher.build_error", push_id=push.push_id)
                continue

            result = await _send_safely(sender, request)
            classification = _classify(result)

            if classification == "sent":
                await _mark_sent(session, push, ts)
                sent += 1
            elif classification == "bad_token":
                await _mark_cancelled(session, push, reason=result.description or "bad_token")
                await _prune_device(session, device.device_id)
                pruned_device_ids.add(device.device_id)
                cancelled += 1
            else:
                # transient — retry next tick unless exhausted
                await _bump_or_fail(session, push, result)
                if push.attempts + 1 >= MAX_ATTEMPTS:
                    failed += 1

        activity_stmt = (
            select(LiveActivityUpdateToken, DeviceRegistration)
            .join(
                DeviceRegistration,
                DeviceRegistration.device_id == LiveActivityUpdateToken.device_id,
            )
            .where(
                LiveActivityUpdateToken.status
                == LiveActivityTokenStatus.active.value,
                LiveActivityUpdateToken.countdown_target.is_not(None),
                LiveActivityUpdateToken.countdown_target <= ts,
            )
            .with_for_update(skip_locked=True)
            .limit(64)
        )
        activity_rows = (await session.execute(activity_stmt)).all()

        for token, device in activity_rows:
            dispatched += 1
            try:
                request = build_live_activity_end_request(
                    update_token=token.update_token_hex,
                    bundle_id=device.bundle_id,
                    snapshot=token.snapshot_json,
                    now=ts,
                )
            except Exception as build_error:  # pragma: no cover — defensive
                await _mark_activity_failed(
                    session,
                    token,
                    reason=f"build_error: {build_error}",
                )
                failed += 1
                logger.exception(
                    "dispatcher.activity_end_build_error",
                    activity_id=token.activity_id,
                )
                continue

            result = await _send_safely(sender, request)
            classification = _classify(result)

            if classification == "sent":
                await _mark_activity_ended(session, token, ts)
                sent += 1
            elif classification == "bad_token":
                await _mark_activity_cancelled(
                    session,
                    token,
                    reason=result.description or "bad_token",
                )
                cancelled += 1
            else:
                await _bump_or_fail_activity(session, token, result)
                if token.attempts + 1 >= MAX_ATTEMPTS:
                    failed += 1

        await session.commit()

    if dispatched:
        logger.info(
            "dispatcher.tick",
            dispatched=dispatched,
            sent=sent,
            failed=failed,
            cancelled=cancelled,
        )
    return TickOutcome(dispatched=dispatched, sent=sent, failed=failed, cancelled=cancelled)


# --- Internals ---


async def _send_safely(sender: PushSender, request: ApnsRequest) -> SendResult:
    try:
        return await sender.send(request)
    except Exception as exc:  # aioapns raises on network errors
        return SendResult(success=False, status="exception", description=str(exc))


def _classify(result: SendResult) -> str:
    """Return 'sent' | 'bad_token' | 'transient'."""
    if result.success:
        return "sent"
    # APNs spec: 410 + reason "BadDeviceToken" / "Unregistered" means the
    # token is dead. Descriptions vary by client lib; match permissively.
    status = str(result.status).lower()
    desc = (result.description or "").lower()
    bad_token_markers = (
        "410",
        "baddevicetoken",
        "bad_device_token",
        "unregistered",
        "devicetokennotfortopic",
    )
    if any(m in status or m in desc for m in bad_token_markers):
        return "bad_token"
    return "transient"


async def _mark_sent(session: AsyncSession, push: ScheduledPush, ts: datetime) -> None:
    # Core-level update bypasses the ORM, so the model's onupdate=func.now()
    # hook does NOT fire. Set updated_at explicitly so the column actually
    # reflects the last state transition.
    await session.execute(
        update(ScheduledPush)
        .where(ScheduledPush.push_id == push.push_id)
        .values(
            status=PushStatus.sent.value,
            sent_at=ts,
            attempts=push.attempts + 1,
            last_error=None,
            updated_at=func.now(),
        )
    )


async def _mark_cancelled(
    session: AsyncSession, push: ScheduledPush, reason: str
) -> None:
    await session.execute(
        update(ScheduledPush)
        .where(ScheduledPush.push_id == push.push_id)
        .values(
            status=PushStatus.cancelled.value,
            attempts=push.attempts + 1,
            last_error=reason,
            updated_at=func.now(),
        )
    )


async def _mark_failed(
    session: AsyncSession, push: ScheduledPush, reason: str
) -> None:
    await session.execute(
        update(ScheduledPush)
        .where(ScheduledPush.push_id == push.push_id)
        .values(
            status=PushStatus.failed.value,
            attempts=push.attempts + 1,
            last_error=reason,
            updated_at=func.now(),
        )
    )


async def _bump_or_fail(
    session: AsyncSession, push: ScheduledPush, result: SendResult
) -> None:
    next_attempts = push.attempts + 1
    if next_attempts >= MAX_ATTEMPTS:
        await _mark_failed(
            session,
            push,
            reason=f"status={result.status} desc={result.description}",
        )
    else:
        await session.execute(
            update(ScheduledPush)
            .where(ScheduledPush.push_id == push.push_id)
            .values(
                attempts=next_attempts,
                last_error=f"status={result.status} desc={result.description}",
                updated_at=func.now(),
            )
        )


async def _mark_activity_ended(
    session: AsyncSession,
    token: LiveActivityUpdateToken,
    ts: datetime,
) -> None:
    await session.execute(
        update(LiveActivityUpdateToken)
        .where(LiveActivityUpdateToken.activity_id == token.activity_id)
        .values(
            status=LiveActivityTokenStatus.ended.value,
            ended_at=ts,
            attempts=token.attempts + 1,
            last_error=None,
            updated_at=func.now(),
        )
    )


async def _mark_activity_cancelled(
    session: AsyncSession,
    token: LiveActivityUpdateToken,
    reason: str,
) -> None:
    await session.execute(
        update(LiveActivityUpdateToken)
        .where(LiveActivityUpdateToken.activity_id == token.activity_id)
        .values(
            status=LiveActivityTokenStatus.cancelled.value,
            attempts=token.attempts + 1,
            last_error=reason,
            updated_at=func.now(),
        )
    )


async def _mark_activity_failed(
    session: AsyncSession,
    token: LiveActivityUpdateToken,
    reason: str,
) -> None:
    await session.execute(
        update(LiveActivityUpdateToken)
        .where(LiveActivityUpdateToken.activity_id == token.activity_id)
        .values(
            status=LiveActivityTokenStatus.failed.value,
            attempts=token.attempts + 1,
            last_error=reason,
            updated_at=func.now(),
        )
    )


async def _bump_or_fail_activity(
    session: AsyncSession,
    token: LiveActivityUpdateToken,
    result: SendResult,
) -> None:
    next_attempts = token.attempts + 1
    if next_attempts >= MAX_ATTEMPTS:
        await _mark_activity_failed(
            session,
            token,
            reason=f"status={result.status} desc={result.description}",
        )
    else:
        await session.execute(
            update(LiveActivityUpdateToken)
            .where(LiveActivityUpdateToken.activity_id == token.activity_id)
            .values(
                attempts=next_attempts,
                last_error=f"status={result.status} desc={result.description}",
                updated_at=func.now(),
            )
        )


async def _prune_device(session: AsyncSession, device_id: str) -> None:
    """Drop a device row so subsequent syncs 404 — the app's next launch
    will re-register with a fresh token."""
    from sqlalchemy import delete

    await session.execute(delete(DeviceRegistration).where(DeviceRegistration.device_id == device_id))
    logger.warning("dispatcher.pruned_device", device_id=device_id)
