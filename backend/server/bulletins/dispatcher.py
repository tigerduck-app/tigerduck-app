"""Bulletin push fan-out.

For each bulletin that's been LLM-processed but never notified, expand it
into (device, bulletin) pairs via the matcher, write pending
`bulletin_dispatches` rows, and hand them to the `PushSender`. Each tick
processes one bulletin at a time so a single slow bulletin doesn't starve
the others, and a crash mid-fan-out leaves the DB in a recoverable state
(some rows sent, remaining still pending).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

import structlog
from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from server.bulletins.matcher import match_device_ids
from server.bulletins.models import (
    Bulletin,
    BulletinDispatch,
    BulletinDispatchStatus,
    BulletinProcessingState,
)
from server.config import Settings
from server.models import DeviceRegistration
from server.push.apns_client import PushSender, SendResult
from server.push.payload import build_alert_request

logger = structlog.get_logger(__name__)

MAX_DISPATCH_ATTEMPTS = 3


@dataclass(frozen=True)
class DispatchOutcome:
    bulletins_handled: int
    pushes_sent: int
    pushes_failed: int
    pushes_cancelled: int
    devices_matched: int


async def dispatch_pending_bulletins(
    session_factory: async_sessionmaker[AsyncSession],
    sender: PushSender,
    settings: Settings,
    *,
    now: datetime | None = None,
    batch_limit: int = 5,
) -> DispatchOutcome:
    """Fan out up to `batch_limit` bulletins per tick."""
    ts = now or datetime.now(timezone.utc)
    totals = [0, 0, 0, 0, 0]  # sent, failed, cancelled, devices, bulletins

    async with session_factory() as session:
        bulletins = (
            (
                await session.execute(
                    select(Bulletin)
                    .where(
                        Bulletin.processing_state
                        == BulletinProcessingState.processed.value,
                        Bulletin.notified_at.is_(None),
                        Bulletin.is_deleted.is_(False),
                    )
                    .order_by(Bulletin.id)
                    .limit(batch_limit)
                )
            )
            .scalars()
            .all()
        )

    for bulletin in bulletins:
        sent, failed, cancelled, matched = await _dispatch_one(
            session_factory, sender, settings, bulletin.id, ts
        )
        totals[0] += sent
        totals[1] += failed
        totals[2] += cancelled
        totals[3] += matched
        totals[4] += 1

    outcome = DispatchOutcome(
        bulletins_handled=totals[4],
        pushes_sent=totals[0],
        pushes_failed=totals[1],
        pushes_cancelled=totals[2],
        devices_matched=totals[3],
    )
    if totals[4]:
        logger.info("bulletins.dispatch.tick", **outcome.__dict__)
    return outcome


async def _dispatch_one(
    session_factory: async_sessionmaker[AsyncSession],
    sender: PushSender,
    settings: Settings,
    bulletin_id: int,
    ts: datetime,
) -> tuple[int, int, int, int]:
    """Fan out a single bulletin. Returns (sent, failed, cancelled, matched)."""
    # Step 1: resolve matching devices + insert pending dispatches in one tx.
    async with session_factory() as session:
        bulletin = await session.get(Bulletin, bulletin_id)
        if bulletin is None or bulletin.canonical_org is None:
            return (0, 0, 0, 0)

        device_ids = await match_device_ids(
            session,
            canonical_org=bulletin.canonical_org,
            content_tags=bulletin.content_tags or [],
        )

        if device_ids:
            await session.execute(
                pg_insert(BulletinDispatch)
                .values(
                    [
                        {
                            "bulletin_id": bulletin_id,
                            "device_id": did,
                            "status": BulletinDispatchStatus.pending.value,
                        }
                        for did in device_ids
                    ]
                )
                # Re-runs after a crash are idempotent thanks to the
                # (bulletin_id, device_id) unique key.
                .on_conflict_do_nothing(
                    index_elements=["bulletin_id", "device_id"]
                )
            )
        await session.commit()

    # Step 2: for each pending dispatch, join the device row and send.
    sent_count = failed_count = cancelled_count = 0
    async with session_factory() as session:
        pending_rows = (
            await session.execute(
                select(BulletinDispatch, DeviceRegistration, Bulletin)
                .join(
                    DeviceRegistration,
                    DeviceRegistration.device_id == BulletinDispatch.device_id,
                )
                .join(Bulletin, Bulletin.id == BulletinDispatch.bulletin_id)
                .where(
                    BulletinDispatch.bulletin_id == bulletin_id,
                    BulletinDispatch.status
                    == BulletinDispatchStatus.pending.value,
                )
            )
        ).all()

        for dispatch, device, bulletin in pending_rows:
            if not device.device_token_hex:
                await session.execute(
                    update(BulletinDispatch)
                    .where(BulletinDispatch.id == dispatch.id)
                    .values(
                        status=BulletinDispatchStatus.cancelled.value,
                        last_error="device has no standard APNs token",
                    )
                )
                cancelled_count += 1
                continue

            # Bulletins arrive here in `processed` state, so `title_clean`
            # has already been normalized by the LLM (prefix stripped,
            # de-shouted). Fall back to the raw title when classification
            # left it NULL — mirrors iOS `BulletinAPIDTO.displayTitle`.
            request = build_alert_request(
                device_token=device.device_token_hex,
                bundle_id=device.bundle_id,
                title=bulletin.title_clean or bulletin.title,
                body=bulletin.summary or bulletin.title_clean or bulletin.title,
                bulletin_id=bulletin.id,
                source_url=bulletin.source_url,
                canonical_org=bulletin.canonical_org or "",
                now=ts,
            )
            result = await _send_safely(sender, request)
            classification = _classify(result)

            if classification == "sent":
                await session.execute(
                    update(BulletinDispatch)
                    .where(BulletinDispatch.id == dispatch.id)
                    .values(
                        status=BulletinDispatchStatus.sent.value,
                        attempts=dispatch.attempts + 1,
                        sent_at=ts,
                        last_error=None,
                    )
                )
                sent_count += 1
            elif classification == "bad_token":
                await session.execute(
                    update(BulletinDispatch)
                    .where(BulletinDispatch.id == dispatch.id)
                    .values(
                        status=BulletinDispatchStatus.cancelled.value,
                        attempts=dispatch.attempts + 1,
                        last_error=result.description or "bad_token",
                    )
                )
                cancelled_count += 1
            else:
                next_attempts = dispatch.attempts + 1
                if next_attempts >= MAX_DISPATCH_ATTEMPTS:
                    await session.execute(
                        update(BulletinDispatch)
                        .where(BulletinDispatch.id == dispatch.id)
                        .values(
                            status=BulletinDispatchStatus.failed.value,
                            attempts=next_attempts,
                            last_error=f"status={result.status} desc={result.description}",
                        )
                    )
                    failed_count += 1
                else:
                    await session.execute(
                        update(BulletinDispatch)
                        .where(BulletinDispatch.id == dispatch.id)
                        .values(
                            attempts=next_attempts,
                            last_error=f"status={result.status} desc={result.description}",
                        )
                    )

        # Step 3: if every dispatch row for this bulletin is terminal
        # (sent/failed/cancelled), stamp notified_at so the next tick
        # doesn't pick the bulletin up again.
        still_pending = (
            await session.execute(
                select(BulletinDispatch.id)
                .where(
                    BulletinDispatch.bulletin_id == bulletin_id,
                    BulletinDispatch.status
                    == BulletinDispatchStatus.pending.value,
                )
                .limit(1)
            )
        ).first()
        if still_pending is None:
            await session.execute(
                update(Bulletin)
                .where(Bulletin.id == bulletin_id)
                .values(notified_at=ts)
            )

        await session.commit()

    return (sent_count, failed_count, cancelled_count, len(pending_rows))


async def _send_safely(sender: PushSender, request) -> SendResult:
    try:
        return await sender.send(request)
    except Exception as exc:  # aioapns raises on network errors
        return SendResult(success=False, status="exception", description=str(exc))


def _classify(result: SendResult) -> str:
    """Shared classifier with scheduler/dispatcher but local copy so changes
    to one push path don't accidentally mutate the other."""
    if result.success:
        return "sent"
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
