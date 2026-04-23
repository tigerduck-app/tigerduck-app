"""Deduplication + UPSERT logic for bulletins.

Two layers of dedup, enforced both here and at the DB level:

1. **external_id** — the numeric ID baked into the source URL. If we've
   already stored a row with the same `(source, external_id)`, treat this
   sighting as a refresh (bump `last_seen_at`) rather than a new row.
2. **content_hash** — sha256 over normalized `title + body_md`. Catches
   reposts where the school assigns a fresh external_id but reuses the
   content. Rows flagged as reposts are stored with
   `processing_state = skipped` so the in-app list can still surface them,
   but the notification fan-out never fires.

Helpers are deliberately pure where possible so unit tests can verify the
normalization rules without a database.
"""

from __future__ import annotations

import hashlib
import re
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timezone

import structlog
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from server.bulletins.models import Bulletin, BulletinProcessingState
from server.bulletins.scraper import ListRow

logger = structlog.get_logger(__name__)


# Collapse any run of whitespace (including fullwidth spaces) into a single
# ASCII space so trivial re-formatting doesn't dodge the content_hash.
_WS_RE = re.compile(r"\s+")


def normalize_for_hash(text: str) -> str:
    """NFKC + casefold + whitespace collapse. Strips leading/trailing space."""
    if not text:
        return ""
    normalized = unicodedata.normalize("NFKC", text).casefold()
    return _WS_RE.sub(" ", normalized).strip()


def compute_content_hash(title: str, body_md: str | None) -> str:
    payload = f"{normalize_for_hash(title)}\n{normalize_for_hash(body_md or '')}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class UpsertOutcome:
    inserted_ids: list[int]      # rows that need LLM processing + notification
    refreshed_count: int         # existing rows whose last_seen_at was bumped
    skipped_reposts: list[int]   # rows inserted but flagged as content dupes


async def upsert_list_rows(
    session: AsyncSession,
    rows: list[ListRow],
    *,
    source: str = "ntust_general",
    now: datetime | None = None,
) -> UpsertOutcome:
    """Reconcile scraped list rows with the `bulletins` table.

    For each `ListRow` not already stored under `(source, external_id)`,
    insert a row in `pending` state. Already-present external_ids get
    `last_seen_at = now`. Content-level dedup (against `content_hash`)
    happens later in `mark_dedup_against_existing` — at the list stage we
    only have the title, not enough to hash reliably.
    """
    ts = now or datetime.now(timezone.utc)
    inserted_ids: list[int] = []
    refreshed = 0

    if not rows:
        return UpsertOutcome(inserted_ids=[], refreshed_count=0, skipped_reposts=[])

    existing_ids = {
        ext
        for (ext,) in (
            await session.execute(
                select(Bulletin.external_id).where(
                    Bulletin.source == source,
                    Bulletin.external_id.in_([r.external_id for r in rows]),
                )
            )
        ).all()
    }

    for row in rows:
        if row.external_id in existing_ids:
            await session.execute(
                update(Bulletin)
                .where(
                    Bulletin.source == source,
                    Bulletin.external_id == row.external_id,
                )
                .values(last_seen_at=ts)
            )
            refreshed += 1
            continue

        bulletin = Bulletin(
            source=source,
            external_id=row.external_id,
            source_url=row.source_url,
            raw_publisher=row.raw_publisher,
            title=row.title,
            posted_at=row.posted_at,
            first_seen_at=ts,
            last_seen_at=ts,
            processing_state=BulletinProcessingState.pending.value,
        )
        session.add(bulletin)
        await session.flush()
        inserted_ids.append(bulletin.id)

    return UpsertOutcome(
        inserted_ids=inserted_ids,
        refreshed_count=refreshed,
        skipped_reposts=[],
    )


async def attach_body_and_dedup(
    session: AsyncSession,
    bulletin_id: int,
    body_md: str,
) -> bool:
    """Second-stage dedup after the detail page has been fetched.

    Returns True if the bulletin is a repost (same content under a different
    external_id) — caller should mark it `skipped` to suppress notification.
    """
    bulletin = await session.get(Bulletin, bulletin_id)
    if bulletin is None:
        raise ValueError(f"bulletin {bulletin_id} not found")

    content_hash = compute_content_hash(bulletin.title, body_md)

    # Look for a PREVIOUSLY-seen bulletin with the same hash. The partial
    # unique index (source, content_hash) would otherwise fail the upsert
    # with an IntegrityError — we want to soft-skip instead.
    existing_id = (
        await session.execute(
            select(Bulletin.id).where(
                Bulletin.source == bulletin.source,
                Bulletin.content_hash == content_hash,
                Bulletin.id != bulletin_id,
            )
        )
    ).scalar_one_or_none()

    is_repost = existing_id is not None
    bulletin.body_md = body_md

    if is_repost:
        # Don't write the hash to the new row — that would violate the
        # unique index. The first row keeps "ownership" of the content_hash.
        bulletin.processing_state = BulletinProcessingState.skipped.value
        bulletin.processing_error = f"content duplicate of bulletin {existing_id}"
        logger.info(
            "bulletins.dedup.repost_detected",
            bulletin_id=bulletin_id,
            original_id=existing_id,
            external_id=bulletin.external_id,
        )
    else:
        bulletin.content_hash = content_hash

    return is_repost
