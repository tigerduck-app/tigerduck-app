"""Bulletin HTTP endpoints.

GET-only endpoints (taxonomy, list, detail) are open — anyone with the app
should see public bulletins. Subscription read/write requires the shared
secret since it mutates per-device state.
"""

from __future__ import annotations

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import and_, delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from server.bulletins.models import Bulletin, BulletinSubscription
from server.bulletins.schemas import (
    BulletinDetail,
    BulletinListResponse,
    BulletinSummary,
    OrgLabel,
    SubscriptionRule,
    SubscriptionsPutRequest,
    SubscriptionsResponse,
    TagLabel,
    TaxonomyResponse,
)
from server.bulletins.taxonomy import (
    DEFAULT_TAGS_FOR_NEW_USER,
    ORG_LABELS,
    TAG_LABELS,
    CanonicalOrg,
    ContentTag,
)
from server.db import SessionDep
from server.models import DeviceRegistration
from server.security import require_shared_secret

logger = structlog.get_logger(__name__)

router = APIRouter(prefix="/bulletins", tags=["bulletins"])
device_router = APIRouter(
    prefix="/devices",
    tags=["bulletin-subscriptions"],
    dependencies=[Depends(require_shared_secret)],
)


@router.get("/taxonomy", response_model=TaxonomyResponse)
async def get_taxonomy() -> TaxonomyResponse:
    """Return the full org + tag lookup so the iOS UI can render the
    subscription editor without hardcoding string IDs."""
    return TaxonomyResponse(
        orgs=[OrgLabel(id=org, label=ORG_LABELS[org]) for org in CanonicalOrg],
        tags=[TagLabel(id=tag, label=TAG_LABELS[tag]) for tag in ContentTag],
        default_tags=sorted(DEFAULT_TAGS_FOR_NEW_USER),
    )


def _coerce_org(raw: str | None) -> CanonicalOrg | None:
    """Tolerate DB rows that still carry a dropped enum value (e.g. during
    the re-classification window after a taxonomy change). Returns None
    for unknown values so the client sees an unclassified row instead of
    the endpoint erroring out."""
    if not raw:
        return None
    try:
        return CanonicalOrg(raw)
    except ValueError:
        return None


def _coerce_tags(raw: list[str] | None) -> list[ContentTag]:
    """Same pattern as `_coerce_org` but for the multi-valued tag array —
    silently drop entries that no longer map to a known enum."""
    result: list[ContentTag] = []
    for t in raw or []:
        try:
            result.append(ContentTag(t))
        except ValueError:
            continue
    return result


def _to_summary(row: Bulletin) -> BulletinSummary:
    return BulletinSummary(
        id=row.id,
        external_id=row.external_id,
        title=row.title,
        title_clean=row.title_clean,
        canonical_org=_coerce_org(row.canonical_org),
        content_tags=_coerce_tags(row.content_tags),
        importance=row.importance,  # type: ignore[arg-type]
        summary=row.summary,
        source_url=row.source_url,
        posted_at=row.posted_at,
        is_deleted=row.is_deleted,
    )


@router.get("", response_model=BulletinListResponse)
async def list_bulletins(
    session: SessionDep,
    limit: int = Query(default=30, ge=1, le=100),
    cursor: int | None = Query(default=None, ge=0),
    include_deleted: bool = Query(default=False),
) -> BulletinListResponse:
    """Paginate processed bulletins, newest first by `posted_at`.

    Sort key is `(posted_at DESC, id DESC)`. Pure `id DESC` shows pinned
    posts (low posted_at, high id from a recent re-scrape) above their
    chronological position; users want them where the publish date puts
    them.

    `cursor` is the id of the last item from the previous page. We
    interpret it as "items strictly older than the cursor row in
    `(posted_at, id)` ordering" so a pinned post never appears on more
    than one page. The cursor sub-query is a single primary-key lookup.

    Deleted bulletins are hidden by default to keep the list coherent
    when the school removes a post.
    """
    stmt = (
        select(Bulletin)
        .where(Bulletin.canonical_org.isnot(None))
        .order_by(Bulletin.posted_at.desc().nulls_last(), Bulletin.id.desc())
        .limit(limit + 1)
    )
    if cursor is not None:
        cursor_row = (
            await session.execute(
                select(Bulletin.posted_at, Bulletin.id).where(Bulletin.id == cursor)
            )
        ).first()
        if cursor_row is not None:
            # A naive `tuple_(posted_at, id) < tuple_(cursor_posted_at, cursor_id)`
            # evaluates to NULL (→ FALSE under WHERE) whenever either side's
            # posted_at is NULL, silently dropping NULLS-LAST rows on page 2+.
            # Decompose into nullable-safe predicates so NULL-posted rows
            # still stream through after the dated tail of page 1.
            if cursor_row.posted_at is not None:
                stmt = stmt.where(
                    or_(
                        Bulletin.posted_at < cursor_row.posted_at,
                        and_(
                            Bulletin.posted_at == cursor_row.posted_at,
                            Bulletin.id < cursor_row.id,
                        ),
                        Bulletin.posted_at.is_(None),
                    )
                )
            else:
                # Cursor sits in the NULL tail already → continue strictly
                # within that tail by id descending.
                stmt = stmt.where(
                    Bulletin.posted_at.is_(None),
                    Bulletin.id < cursor_row.id,
                )
        # else: cursor row vanished between requests; fall through and
        # serve from the start. Client dedupes by id.
    if not include_deleted:
        stmt = stmt.where(Bulletin.is_deleted.is_(False))

    rows = (await session.execute(stmt)).scalars().all()
    has_next = len(rows) > limit
    items = [_to_summary(r) for r in rows[:limit]]
    next_cursor = items[-1].id if has_next and items else None
    return BulletinListResponse(items=items, next_cursor=next_cursor)


@router.get("/{bulletin_id}", response_model=BulletinDetail)
async def get_bulletin(bulletin_id: int, session: SessionDep) -> BulletinDetail:
    row = await session.get(Bulletin, bulletin_id)
    if row is None:
        raise HTTPException(status_code=404, detail="bulletin not found")
    base = _to_summary(row).model_dump()
    return BulletinDetail(
        **base,
        body_clean=row.body_clean,
        body_md=row.body_md,
        raw_publisher=row.raw_publisher,
    )


# -- Subscriptions ----------------------------------------------------------


async def _ensure_device(session: AsyncSession, device_id: str) -> DeviceRegistration:
    device = await session.get(DeviceRegistration, device_id)
    if device is None:
        raise HTTPException(status_code=404, detail="device not registered")
    return device


def _rule_from_db(row: BulletinSubscription) -> SubscriptionRule:
    # Self-healing on read: a saved rule may reference an enum that was
    # later dropped from the taxonomy (e.g. after a catalog reshuffle).
    # Silently strip the dropped values — when the iOS client saves next,
    # the PUT body will carry only the surviving ones and the row gets
    # cleaned on disk.
    orgs: list[CanonicalOrg] = []
    for o in row.orgs or []:
        try:
            orgs.append(CanonicalOrg(o))
        except ValueError:
            continue
    tags: list[ContentTag] = []
    for t in row.tags or []:
        try:
            tags.append(ContentTag(t))
        except ValueError:
            continue
    return SubscriptionRule(
        id=row.id,
        name=row.name,
        orgs=orgs,
        tags=tags,
        mode=row.mode,  # type: ignore[arg-type]
        enabled=row.enabled,
    )


@device_router.get(
    "/{device_id}/subscriptions", response_model=SubscriptionsResponse
)
async def list_subscriptions(
    device_id: str, session: SessionDep
) -> SubscriptionsResponse:
    """Return the device's subscription rules.

    The device row may not exist yet on first launch — APNs token fetch on
    iOS races with the subscriptions load. Returning an empty list (instead
    of 404) lets the client show the editor immediately without the client
    needing a special-case catch. The PUT path still requires a registered
    device so a saved ruleset can't orphan.
    """
    device = await session.get(DeviceRegistration, device_id)
    if device is None:
        return SubscriptionsResponse(device_id=device_id, rules=[])
    rows = (
        (
            await session.execute(
                select(BulletinSubscription)
                .where(BulletinSubscription.device_id == device_id)
                .order_by(BulletinSubscription.id)
            )
        )
        .scalars()
        .all()
    )
    return SubscriptionsResponse(
        device_id=device_id, rules=[_rule_from_db(r) for r in rows]
    )


@device_router.put(
    "/{device_id}/subscriptions",
    response_model=SubscriptionsResponse,
    status_code=status.HTTP_200_OK,
)
async def replace_subscriptions(
    device_id: str,
    payload: SubscriptionsPutRequest,
    session: SessionDep,
) -> SubscriptionsResponse:
    """Replace the device's entire rule set. Idempotent snapshot style —
    the iOS app sends the full list every save so we don't need per-row
    CRUD churn and can't leak orphan rules after a partial write."""
    await _ensure_device(session, device_id)

    # Wipe existing rules for this device and re-insert in one tx. The
    # alternative (diff + upsert) adds complexity for no user-visible win.
    await session.execute(
        delete(BulletinSubscription).where(
            BulletinSubscription.device_id == device_id
        )
    )
    for rule in payload.rules:
        session.add(
            BulletinSubscription(
                device_id=device_id,
                name=rule.name,
                orgs=[o.value for o in rule.orgs],
                tags=[t.value for t in rule.tags],
                mode=rule.mode,
                enabled=rule.enabled,
            )
        )
    await session.flush()
    rows = (
        (
            await session.execute(
                select(BulletinSubscription)
                .where(BulletinSubscription.device_id == device_id)
                .order_by(BulletinSubscription.id)
            )
        )
        .scalars()
        .all()
    )
    logger.info(
        "bulletin.subscriptions.replaced",
        device_id=device_id,
        rule_count=len(rows),
    )
    return SubscriptionsResponse(
        device_id=device_id, rules=[_rule_from_db(r) for r in rows]
    )
