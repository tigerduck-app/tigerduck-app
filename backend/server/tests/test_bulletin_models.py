"""Sanity checks for the bulletin schema.

Does not exercise the full pipeline — just ensures the tables, constraints,
and taxonomy constants load cleanly and behave as intended. End-to-end
flows land in later checkpoints (scraper / LLM / dispatcher).
"""

from __future__ import annotations

import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker

from server.bulletins.models import (
    Bulletin,
    BulletinDispatch,
    BulletinProcessingState,
    BulletinSubscription,
)
from server.bulletins.taxonomy import (
    CanonicalOrg,
    ContentTag,
    DEFAULT_TAGS_FOR_NEW_USER,
    ORG_LABELS,
    SubscriptionMode,
    TAG_LABELS,
)
from server.models import DeviceRegistration

_async = pytest.mark.asyncio(loop_scope="session")


def test_every_canonical_org_has_label() -> None:
    for org in CanonicalOrg:
        assert org in ORG_LABELS, f"missing label for {org}"
        assert ORG_LABELS[org].strip()


def test_every_content_tag_has_label() -> None:
    for tag in ContentTag:
        assert tag in TAG_LABELS, f"missing label for {tag}"
        assert TAG_LABELS[tag].strip()


def test_free_meal_is_in_taxonomy() -> None:
    assert ContentTag.free_meal.value == "free_meal"
    assert "便當" in TAG_LABELS[ContentTag.free_meal]


def test_default_tags_are_a_conservative_subset() -> None:
    assert ContentTag.important in DEFAULT_TAGS_FOR_NEW_USER
    assert ContentTag.free_meal in DEFAULT_TAGS_FOR_NEW_USER
    # Should not spam the user with every event
    assert ContentTag.event not in DEFAULT_TAGS_FOR_NEW_USER


def test_subscription_mode_values() -> None:
    assert {m.value for m in SubscriptionMode} == {"AND", "OR"}


@_async
async def test_bulletin_upsert_unique_on_source_and_external_id(
    prepared_engine: AsyncEngine,
) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    async with factory() as session:
        session.add(
            Bulletin(
                source="ntust_general",
                external_id="99999",
                source_url="https://bulletin.ntust.edu.tw/p/406-1045-99999.php",
                title="t",
            )
        )
        await session.commit()

    async with factory() as session:
        session.add(
            Bulletin(
                source="ntust_general",
                external_id="99999",
                source_url="https://bulletin.ntust.edu.tw/p/406-1045-99999.php",
                title="duplicate",
            )
        )
        with pytest.raises(IntegrityError):
            await session.commit()


@_async
async def test_content_hash_dedup_across_external_ids(
    prepared_engine: AsyncEngine,
) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    async with factory() as session:
        session.add_all(
            [
                Bulletin(
                    source="ntust_general",
                    external_id="100001",
                    source_url="https://x/1",
                    title="t1",
                    content_hash="a" * 64,
                ),
                Bulletin(
                    source="ntust_general",
                    external_id="100002",
                    source_url="https://x/2",
                    title="t2",
                    content_hash="a" * 64,  # same hash → different external_id
                ),
            ]
        )
        with pytest.raises(IntegrityError):
            await session.commit()


@_async
async def test_bulletin_defaults(prepared_engine: AsyncEngine) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    async with factory() as session:
        bul = Bulletin(
            source="ntust_general",
            external_id="200001",
            source_url="https://x/200001",
            title="pending default",
        )
        session.add(bul)
        await session.commit()
        await session.refresh(bul)
        assert bul.processing_state == BulletinProcessingState.pending.value
        assert bul.content_tags == []
        assert bul.is_deleted is False
        assert bul.notified_at is None


@_async
async def test_subscription_mode_check_constraint(
    prepared_engine: AsyncEngine,
) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    async with factory() as session:
        session.add(
            DeviceRegistration(
                device_id="dev-sub-1",
                user_id="u1",
                pts_token_hex="00",
                bundle_id="b",
                attrs_type="a",
                apns_env="development",
            )
        )
        await session.commit()

    async with factory() as session:
        session.add(
            BulletinSubscription(
                device_id="dev-sub-1",
                name="bad-mode",
                orgs=[],
                tags=[],
                mode="XOR",  # not in check list
            )
        )
        with pytest.raises(IntegrityError):
            await session.commit()


@_async
async def test_dispatch_unique_bulletin_device(
    prepared_engine: AsyncEngine,
) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    async with factory() as session:
        session.add(
            DeviceRegistration(
                device_id="dev-disp",
                user_id="u1",
                pts_token_hex="00",
                bundle_id="b",
                attrs_type="a",
                apns_env="development",
            )
        )
        bul = Bulletin(
            source="ntust_general",
            external_id="300001",
            source_url="https://x/300001",
            title="t",
        )
        session.add(bul)
        await session.commit()
        bul_id = bul.id

    async with factory() as session:
        session.add(BulletinDispatch(bulletin_id=bul_id, device_id="dev-disp"))
        await session.commit()

    async with factory() as session:
        session.add(BulletinDispatch(bulletin_id=bul_id, device_id="dev-disp"))
        with pytest.raises(IntegrityError):
            await session.commit()


@_async
async def test_subscription_array_round_trip(prepared_engine: AsyncEngine) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    async with factory() as session:
        session.add(
            DeviceRegistration(
                device_id="dev-arr",
                user_id="u",
                pts_token_hex="00",
                bundle_id="b",
                attrs_type="a",
                apns_env="development",
            )
        )
        await session.commit()

    async with factory() as session:
        session.add(
            BulletinSubscription(
                device_id="dev-arr",
                name="scholarship-watch",
                orgs=[CanonicalOrg.student_affairs.value],
                tags=[ContentTag.scholarship.value, ContentTag.important.value],
                mode=SubscriptionMode.AND.value,
            )
        )
        await session.commit()

    async with factory() as session:
        row = (
            await session.execute(
                select(BulletinSubscription).where(
                    BulletinSubscription.device_id == "dev-arr"
                )
            )
        ).scalar_one()
        assert row.orgs == [CanonicalOrg.student_affairs.value]
        assert set(row.tags) == {
            ContentTag.scholarship.value,
            ContentTag.important.value,
        }
        assert row.mode == "AND"
        assert row.enabled is True
