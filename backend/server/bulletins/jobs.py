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
from sqlalchemy import select, update
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
    wide pool for calls that only happen every minute or so."""
    return httpx.AsyncClient(
        follow_redirects=True,
        headers={"User-Agent": "TigerDuckBulletinBot/0.1"},
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


async def process_job(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    llm: LLMProvider,
    *,
    http_client_factory: HttpClientFactory = default_http_client_factory,
    batch_limit: int = 10,
) -> int:
    """Drain up to `batch_limit` pending bulletins through detail + LLM."""
    async with session_factory() as session:
        pending = (
            (
                await session.execute(
                    select(Bulletin)
                    .where(
                        Bulletin.processing_state
                        == BulletinProcessingState.pending.value,
                        Bulletin.processing_attempts
                        < settings.bulletin_max_process_attempts,
                        Bulletin.is_deleted.is_(False),
                    )
                    .order_by(Bulletin.id)
                    .limit(batch_limit)
                )
            )
            .scalars()
            .all()
        )

    if not pending:
        return 0

    processed = 0
    async with http_client_factory() as http_client:
        for bul in pending:
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
        await _mark_failed(session_factory, bulletin_id, f"detail fetch: {exc}")
        return

    if detail is None:
        await _mark_failed(session_factory, bulletin_id, "trafilatura empty extract")
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
        await _mark_failed(session_factory, bulletin_id, f"llm: {exc}")
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
                processing_attempts=Bulletin.processing_attempts + 1,
            )
        )
        await session.commit()


async def _mark_failed(
    session_factory: async_sessionmaker[AsyncSession],
    bulletin_id: int,
    reason: str,
) -> None:
    async with session_factory() as session:
        bul = await session.get(Bulletin, bulletin_id)
        if bul is None:
            return
        next_attempts = bul.processing_attempts + 1
        # Stay in pending until attempts exhausted, then flip to failed so
        # the job stops picking it up.
        stays_pending = next_attempts < 3  # duplicates settings.bulletin_max_process_attempts default; safe since we also gate at the SELECT
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
                processing_attempts=next_attempts,
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
