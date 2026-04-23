"""APScheduler job handlers for the bulletin pipeline.

Three independent jobs so a stall in one doesn't starve the others:

* `scrape_job` — GETs the list page, UPSERTs rows, bumps last_seen_at,
  and marks disappeared rows `is_deleted` once they've missed N cycles.
* `process_job` — drains `processing_state = pending` rows: fetches the
  detail page, runs dedup, and calls the LLM to classify. Respects
  `bulletin_max_process_attempts`.
* `dispatch_job` — fan-out via `dispatcher.dispatch_pending_bulletins`.

Each handler is idempotent — the scheduler can re-enter the job without
re-notifying devices (the unique index + `notified_at` stamp do the work).
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from datetime import datetime, timedelta, timezone

import httpx
import structlog
from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from server.bulletins.dedup import attach_body_and_dedup, upsert_list_rows
from server.bulletins.detail import fetch_detail
from server.bulletins.dispatcher import dispatch_pending_bulletins
from server.bulletins.llm.base import LLMError, LLMProvider
from server.bulletins.models import Bulletin, BulletinProcessingState
from server.bulletins.scraper import fetch_list
from server.config import Settings
from server.push.apns_client import PushSender

logger = structlog.get_logger(__name__)

HttpClientFactory = Callable[[], httpx.AsyncClient]


def default_http_client_factory() -> httpx.AsyncClient:
    """Each job call builds its own client — simpler than juggling an app-
    wide pool for calls that only happen every minute or so.

    TLS verification is disabled because the NTUST bulletin pipeline hops
    through multiple ntust.edu.tw subdomains (obei, admissions, library…)
    whose servers ship incomplete cert chains or certs missing RFC 5280
    extensions. OpenSSL 3 on Debian rejects all of them; curl/macOS
    tolerate them via AIA chasing / lax parsing. Since the content is
    public and nothing sensitive flows out, trading TLS strictness for
    success on all ~600 bulletins is the right call at MVP scale. If a
    later phase needs genuine integrity, pin the NTUST root manually and
    re-enable verify.
    """
    return httpx.AsyncClient(
        follow_redirects=True,
        headers={"User-Agent": "TigerDuckBulletinBot/0.1"},
        verify=False,
    )


async def scrape_job(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    *,
    http_client_factory: HttpClientFactory = default_http_client_factory,
    now: datetime | None = None,
) -> int:
    """Fetch the list page and reconcile with DB. Returns #inserted."""
    ts = now or datetime.now(timezone.utc)
    async with http_client_factory() as client:
        rows = await fetch_list(settings.bulletin_list_url, client)

    async with session_factory() as session:
        outcome = await upsert_list_rows(session, rows, now=ts)
        await _mark_stale_deleted(session, settings, ts)
        await session.commit()

    logger.info(
        "bulletins.scrape_job.done",
        inserted=len(outcome.inserted_ids),
        refreshed=outcome.refreshed_count,
    )
    return len(outcome.inserted_ids)


async def _mark_stale_deleted(
    session: AsyncSession, settings: Settings, ts: datetime
) -> int:
    """Flip rows missing from the last N scrape cycles to is_deleted.

    We only mark — we don't notify devices about deletions (the in-app
    list just hides them). Re-appearance later bumps last_seen_at and the
    flag stays `true`, which is fine because the front page ranking is what
    the user actually cares about.
    """
    threshold = ts - timedelta(
        seconds=settings.bulletin_scrape_interval_seconds
        * settings.bulletin_stale_cycles
    )
    result = await session.execute(
        update(Bulletin)
        .where(
            Bulletin.is_deleted.is_(False),
            Bulletin.last_seen_at < threshold,
        )
        .values(is_deleted=True)
    )
    return result.rowcount or 0


async def claim_pending_bulletins(
    session_factory: async_sessionmaker[AsyncSession],
    *,
    max_attempts: int,
    limit: int,
) -> list[Bulletin]:
    """Atomically reserve up to `limit` pending bulletins for processing.

    Two workers running in parallel (e.g. the scheduler's `process_job` and
    the one-shot backfill script) must not pick the same row — without this
    they would both hit the LLM with the same payload and race on the final
    state update. We use SELECT ... FOR UPDATE SKIP LOCKED inside a single
    transaction, increment `processing_attempts`, and commit; any other
    worker running the same SELECT concurrently just skips the locked ids.

    The attempts bump here is the AUTHORITATIVE place — downstream success
    and failure paths no longer re-increment, they only transition state.
    That way an exhausted bulletin is defined precisely as
    `processing_attempts >= max_attempts` at the moment of finalization.
    """
    async with session_factory() as session:
        claim_ids = (
            await session.execute(
                select(Bulletin.id)
                .where(
                    Bulletin.processing_state
                    == BulletinProcessingState.pending.value,
                    Bulletin.processing_attempts < max_attempts,
                    Bulletin.is_deleted.is_(False),
                )
                .order_by(Bulletin.id)
                .limit(limit)
                .with_for_update(skip_locked=True)
            )
        ).scalars().all()

        if not claim_ids:
            return []

        await session.execute(
            update(Bulletin)
            .where(Bulletin.id.in_(claim_ids))
            .values(processing_attempts=Bulletin.processing_attempts + 1)
        )
        claimed = (
            await session.execute(
                select(Bulletin)
                .where(Bulletin.id.in_(claim_ids))
                .order_by(Bulletin.id)
            )
        ).scalars().all()
        await session.commit()

    return list(claimed)


async def process_job(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    llm: LLMProvider,
    *,
    http_client_factory: HttpClientFactory = default_http_client_factory,
    batch_limit: int = 10,
) -> int:
    """Drain up to `batch_limit` pending bulletins through detail + LLM."""
    claimed = await claim_pending_bulletins(
        session_factory,
        max_attempts=settings.bulletin_max_process_attempts,
        limit=batch_limit,
    )
    if not claimed:
        return 0

    processed = 0
    async with http_client_factory() as http_client:
        for bul in claimed:
            try:
                await _process_one(session_factory, settings, llm, http_client, bul.id)
                processed += 1
            except Exception as exc:  # noqa: BLE001 — top-level job guard
                logger.exception(
                    "bulletins.process_job.unhandled",
                    bulletin_id=bul.id,
                    error=str(exc)[:200],
                )

    logger.info("bulletins.process_job.done", processed=processed)
    return processed


async def _process_one(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    llm: LLMProvider,
    http_client: httpx.AsyncClient,
    bulletin_id: int,
) -> None:
    async with session_factory() as session:
        bulletin = await session.get(Bulletin, bulletin_id)
        if bulletin is None:
            return
        source_url = bulletin.source_url
        title = bulletin.title
        raw_publisher = bulletin.raw_publisher or ""

    try:
        detail = await fetch_detail(source_url, http_client)
    except httpx.HTTPError as exc:
        await _mark_failed(session_factory, settings, bulletin_id, f"detail fetch: {exc}")
        return

    if detail is None:
        await _mark_failed(session_factory, settings, bulletin_id, "trafilatura empty extract")
        return

    # First: persist body_md + dedup against existing content_hash.
    async with session_factory() as session:
        is_repost = await attach_body_and_dedup(session, bulletin_id, detail.body_md)
        await session.commit()
        if is_repost:
            return

    # Then: LLM classify.
    try:
        meta = await llm.classify(
            title=title,
            raw_publisher=raw_publisher,
            body_md=detail.body_md,
        )
    except LLMError as exc:
        await _mark_failed(session_factory, settings, bulletin_id, f"llm: {exc}")
        return

    async with session_factory() as session:
        await session.execute(
            update(Bulletin)
            .where(Bulletin.id == bulletin_id)
            .values(
                canonical_org=meta.canonical_org.value,
                content_tags=[t.value for t in meta.content_tags],
                summary=meta.summary,
                body_clean=meta.body_clean,
                importance=meta.importance.value,
                processing_state=BulletinProcessingState.processed.value,
                processing_error=None,
                # processing_attempts already bumped at claim time
            )
        )
        await session.commit()


async def _mark_failed(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    bulletin_id: int,
    reason: str,
) -> None:
    """Mark a claimed bulletin as failed.

    processing_attempts has already been bumped at claim time; here we only
    decide whether to keep the row in `pending` (will retry next tick) or
    flip to `failed` (exhausted the attempt budget).
    """
    async with session_factory() as session:
        bul = await session.get(Bulletin, bulletin_id)
        if bul is None:
            return
        stays_pending = bul.processing_attempts < settings.bulletin_max_process_attempts
        state = (
            BulletinProcessingState.pending.value
            if stays_pending
            else BulletinProcessingState.failed.value
        )
        await session.execute(
            update(Bulletin)
            .where(Bulletin.id == bulletin_id)
            .values(
                processing_state=state,
                processing_error=reason[:500],
                # processing_attempts already bumped at claim time
            )
        )
        await session.commit()
    logger.warning(
        "bulletins.process_job.marked_failed", bulletin_id=bulletin_id, reason=reason
    )


async def dispatch_job(
    session_factory: async_sessionmaker[AsyncSession],
    sender: PushSender,
    settings: Settings,
) -> None:
    await dispatch_pending_bulletins(session_factory, sender, settings)


async def retention_job(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> int:
    """Prune bulletins that fell off the source list and are now older than
    `bulletin_retention_days`. `bulletin_dispatches` rows cascade-delete
    via FK, so we only need to target the parent table.

    Only rows with `is_deleted=true` are eligible — anything still visible
    on the bulletin board keeps refreshing its `last_seen_at` through the
    scrape job and therefore never falls past the cutoff here.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(
        days=settings.bulletin_retention_days
    )
    async with session_factory() as session:
        result = await session.execute(
            delete(Bulletin).where(
                Bulletin.is_deleted.is_(True),
                Bulletin.last_seen_at < cutoff,
            )
        )
        await session.commit()
    deleted = result.rowcount or 0
    logger.info(
        "bulletins.retention_job.done",
        deleted=deleted,
        cutoff=cutoff.isoformat(),
        retention_days=settings.bulletin_retention_days,
    )
    return deleted
