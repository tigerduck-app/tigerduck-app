"""Bulletin HTTP endpoints.

GET-only endpoints (taxonomy, list, detail) are open — anyone with the app
should see public bulletins. Subscription read/write requires the shared
secret since it mutates per-device state.
"""

from __future__ import annotations

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import delete, select
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


def _to_summary(row: Bulletin) -> BulletinSummary:
    return BulletinSummary(
        id=row.id,
        external_id=row.external_id,
        title=row.title,
        canonical_org=CanonicalOrg(row.canonical_org) if row.canonical_org else None,
        content_tags=[ContentTag(t) for t in (row.content_tags or [])],
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
    """Paginate processed bulletins, newest first. `cursor` is the last
    seen bulletin id from a previous page — we fetch rows strictly smaller
    than that id. Deleted bulletins are hidden by default to keep the list
    coherent when the school removes a post."""
    stmt = (
        select(Bulletin)
        .where(Bulletin.canonical_org.isnot(None))
        .order_by(Bulletin.id.desc())
        .limit(limit + 1)
    )
    if cursor is not None:
        stmt = stmt.where(Bulletin.id < cursor)
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
    return SubscriptionRule(
        id=row.id,
        name=row.name,
        orgs=[CanonicalOrg(o) for o in (row.orgs or [])],
        tags=[ContentTag(t) for t in (row.tags or [])],
        mode=row.mode,  # type: ignore[arg-type]
        enabled=row.enabled,
    )


@device_router.get(
    "/{device_id}/subscriptions", response_model=SubscriptionsResponse
)
async def list_subscriptions(
    device_id: str, session: SessionDep
) -> SubscriptionsResponse:
    await _ensure_device(session, device_id)
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
