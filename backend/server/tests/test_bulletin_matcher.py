"""Tests for subscription rule matching."""

from __future__ import annotations

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker

from server.bulletins.matcher import (
    Rule,
    device_matches,
    match_device_ids,
    rule_hits,
)
from server.bulletins.models import BulletinSubscription
from server.bulletins.taxonomy import CanonicalOrg, ContentTag, SubscriptionMode
from server.models import DeviceRegistration

_async = pytest.mark.asyncio(loop_scope="session")


# ---- Pure-function rule matching ------------------------------------------


def _rule(orgs: set[str] = None, tags: set[str] = None, mode: str = "AND") -> Rule:
    return Rule(
        orgs=frozenset(orgs or ()),
        tags=frozenset(tags or ()),
        mode=SubscriptionMode(mode),
    )


def test_and_rule_requires_both_dimensions() -> None:
    rule = _rule(
        orgs={CanonicalOrg.student_affairs.value},
        tags={ContentTag.scholarship.value},
        mode="AND",
    )
    assert rule_hits(
        rule,
        canonical_org=CanonicalOrg.student_affairs.value,
        content_tags=[ContentTag.scholarship.value],
    )
    assert not rule_hits(
        rule,
        canonical_org=CanonicalOrg.library.value,
        content_tags=[ContentTag.scholarship.value],
    )
    assert not rule_hits(
        rule,
        canonical_org=CanonicalOrg.student_affairs.value,
        content_tags=[ContentTag.event.value],
    )


def test_or_rule_fires_on_either_dimension() -> None:
    rule = _rule(
        orgs={CanonicalOrg.library.value},
        tags={ContentTag.free_meal.value},
        mode="OR",
    )
    assert rule_hits(
        rule,
        canonical_org=CanonicalOrg.library.value,
        content_tags=[],
    )
    assert rule_hits(
        rule,
        canonical_org=CanonicalOrg.student_affairs.value,
        content_tags=[ContentTag.free_meal.value],
    )
    assert not rule_hits(
        rule,
        canonical_org=CanonicalOrg.student_affairs.value,
        content_tags=[ContentTag.event.value],
    )


def test_empty_orgs_is_wildcard() -> None:
    rule = _rule(tags={ContentTag.free_meal.value}, mode="AND")
    assert rule_hits(
        rule,
        canonical_org=CanonicalOrg.library.value,
        content_tags=[ContentTag.free_meal.value],
    )
    assert not rule_hits(
        rule,
        canonical_org=CanonicalOrg.library.value,
        content_tags=[],
    )


def test_empty_tags_is_wildcard() -> None:
    rule = _rule(orgs={CanonicalOrg.academic_affairs.value}, mode="AND")
    assert rule_hits(
        rule,
        canonical_org=CanonicalOrg.academic_affairs.value,
        content_tags=[],
    )
    assert not rule_hits(
        rule,
        canonical_org=CanonicalOrg.library.value,
        content_tags=[],
    )


def test_fully_empty_rule_matches_everything() -> None:
    rule = _rule(mode="AND")
    assert rule_hits(rule, canonical_org="anything", content_tags=[])


def test_device_matches_takes_union_of_rules() -> None:
    rules = [
        _rule(
            orgs={CanonicalOrg.student_affairs.value},
            tags={ContentTag.scholarship.value},
        ),
        _rule(tags={ContentTag.free_meal.value}),
    ]
    # Second rule (any org + free_meal) matches even though first doesn't
    assert device_matches(
        rules,
        canonical_org=CanonicalOrg.library.value,
        content_tags=[ContentTag.free_meal.value],
    )
    # Neither rule matches a pure library event
    assert not device_matches(
        rules,
        canonical_org=CanonicalOrg.library.value,
        content_tags=[ContentTag.event.value],
    )


# ---- DB-level matching ----------------------------------------------------


@_async
async def test_match_device_ids_skips_device_without_standard_token(
    prepared_engine: AsyncEngine,
) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    async with factory() as session:
        # Device A has a standard token → eligible.
        session.add(
            DeviceRegistration(
                device_id="dev-with-token",
                user_id="u1",
                pts_token_hex="pts-a",
                device_token_hex="alert-token-a",
                bundle_id="b",
                attrs_type="a",
                apns_env="development",
            )
        )
        # Device B does NOT → must be skipped.
        session.add(
            DeviceRegistration(
                device_id="dev-no-token",
                user_id="u2",
                pts_token_hex="pts-b",
                device_token_hex=None,
                bundle_id="b",
                attrs_type="a",
                apns_env="development",
            )
        )
        await session.flush()
        session.add_all(
            [
                BulletinSubscription(
                    device_id="dev-with-token",
                    orgs=[],
                    tags=[ContentTag.free_meal.value],
                    mode="AND",
                ),
                BulletinSubscription(
                    device_id="dev-no-token",
                    orgs=[],
                    tags=[ContentTag.free_meal.value],
                    mode="AND",
                ),
            ]
        )
        await session.commit()

    async with factory() as session:
        ids = await match_device_ids(
            session,
            canonical_org=CanonicalOrg.library.value,
            content_tags=[ContentTag.free_meal.value],
        )
    assert "dev-with-token" in ids
    assert "dev-no-token" not in ids


@_async
async def test_match_device_ids_honors_disabled_flag(
    prepared_engine: AsyncEngine,
) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    async with factory() as session:
        session.add(
            DeviceRegistration(
                device_id="dev-disabled",
                user_id="u",
                pts_token_hex="pts",
                device_token_hex="alert",
                bundle_id="b",
                attrs_type="a",
                apns_env="development",
            )
        )
        await session.flush()
        session.add(
            BulletinSubscription(
                device_id="dev-disabled",
                orgs=[CanonicalOrg.library.value],
                tags=[],
                mode="AND",
                enabled=False,
            )
        )
        await session.commit()

    async with factory() as session:
        ids = await match_device_ids(
            session,
            canonical_org=CanonicalOrg.library.value,
            content_tags=[],
        )
    assert "dev-disabled" not in ids


@_async
async def test_match_device_ids_union_across_multiple_rules(
    prepared_engine: AsyncEngine,
) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    async with factory() as session:
        session.add(
            DeviceRegistration(
                device_id="dev-multi",
                user_id="u",
                pts_token_hex="pts",
                device_token_hex="alert",
                bundle_id="b",
                attrs_type="a",
                apns_env="development",
            )
        )
        await session.flush()
        session.add_all(
            [
                BulletinSubscription(
                    device_id="dev-multi",
                    name="学务处獎學金",
                    orgs=[CanonicalOrg.student_affairs.value],
                    tags=[ContentTag.scholarship.value],
                    mode="AND",
                ),
                BulletinSubscription(
                    device_id="dev-multi",
                    name="任何免費便當",
                    orgs=[],
                    tags=[ContentTag.free_meal.value],
                    mode="AND",
                ),
            ]
        )
        await session.commit()

    async with factory() as session:
        # Matches rule 2 (free_meal from anywhere). Other test fixtures in
        # the same session may contribute other devices — we only assert
        # that dev-multi is covered.
        ids = await match_device_ids(
            session,
            canonical_org=CanonicalOrg.library.value,
            content_tags=[ContentTag.free_meal.value],
        )
        assert "dev-multi" in ids

        # Matches rule 1 (student_affairs + scholarship)
        ids = await match_device_ids(
            session,
            canonical_org=CanonicalOrg.student_affairs.value,
            content_tags=[ContentTag.scholarship.value],
        )
        assert "dev-multi" in ids

        # Matches neither — library event without food
        ids = await match_device_ids(
            session,
            canonical_org=CanonicalOrg.library.value,
            content_tags=[ContentTag.event.value],
        )
        assert "dev-multi" not in ids
