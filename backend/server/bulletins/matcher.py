"""Subscription rule matching.

A device gets notified about a bulletin if ANY of its enabled rules matches.
Each rule is a tuple of `(orgs, tags, mode)`:

* Empty `orgs` = wildcard on the publisher dimension.
* Empty `tags` = wildcard on the content-tag dimension.
* `mode="AND"` — both dimensions must pass.
* `mode="OR"`  — either dimension is enough.

`rule_hits` is a pure function so unit tests don't need the DB; the SQL
side in `match_device_ids` restricts to enabled rows and joins against
`device_registrations.device_token_hex` (devices without a standard APNs
token cannot receive alert pushes, so we skip them early).
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass

import structlog
from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from server.bulletins.models import BulletinSubscription
from server.bulletins.taxonomy import SubscriptionMode
from server.models import DeviceRegistration, DevicePlatform

logger = structlog.get_logger(__name__)


@dataclass(frozen=True)
class Rule:
    orgs: frozenset[str]
    tags: frozenset[str]
    mode: SubscriptionMode


def rule_hits(
    rule: Rule,
    *,
    canonical_org: str | None,
    content_tags: Sequence[str],
) -> bool:
    """Return True if the bulletin's (org, tags) trigger this rule."""
    orgs_ok = not rule.orgs or (canonical_org is not None and canonical_org in rule.orgs)
    tags_ok = not rule.tags or bool(rule.tags.intersection(content_tags))

    if rule.mode is SubscriptionMode.AND:
        return orgs_ok and tags_ok
    return orgs_ok or tags_ok


def device_matches(
    rules: Iterable[Rule],
    *,
    canonical_org: str | None,
    content_tags: Sequence[str],
) -> bool:
    """A device with no rules should receive nothing. Otherwise OR across
    enabled rules."""
    return any(
        rule_hits(r, canonical_org=canonical_org, content_tags=content_tags)
        for r in rules
    )


async def match_device_ids(
    session: AsyncSession,
    *,
    canonical_org: str,
    content_tags: Sequence[str],
) -> list[str]:
    """Return device_ids that should be notified about a bulletin.

    Filters at the SQL level to:
    * enabled subscriptions only
    * devices with a non-null `device_token_hex` (no standard token → no
      alert-push possible).

    Rule matching itself runs in Python because the array-overlap semantics
    of `mode` plus wildcard-on-empty-array is awkward to express purely in
    SQL without turning into a multi-branch CASE.
    """
    stmt = (
        select(
            BulletinSubscription.device_id,
            BulletinSubscription.orgs,
            BulletinSubscription.tags,
            BulletinSubscription.mode,
        )
        .join(
            DeviceRegistration,
            DeviceRegistration.device_id == BulletinSubscription.device_id,
        )
        .where(
            BulletinSubscription.enabled.is_(True),
            # Apple devices need an APNs standard token (`device_token_hex`);
            # Android devices need an FCM registration token, which lives in
            # `pts_token_hex`. Originally only the apple branch was checked,
            # which silently excluded every Android device from matching.
            or_(
                and_(
                    DeviceRegistration.platform == DevicePlatform.apple.value,
                    DeviceRegistration.device_token_hex.isnot(None),
                ),
                and_(
                    DeviceRegistration.platform == DevicePlatform.android.value,
                    DeviceRegistration.pts_token_hex.isnot(None),
                    DeviceRegistration.pts_token_hex != "",
                ),
            ),
        )
    )
    rows = (await session.execute(stmt)).all()

    matched: set[str] = set()
    per_device_rules: dict[str, list[Rule]] = {}
    for device_id, orgs, tags, mode in rows:
        rule = Rule(
            orgs=frozenset(orgs or ()),
            tags=frozenset(tags or ()),
            mode=SubscriptionMode(mode),
        )
        per_device_rules.setdefault(device_id, []).append(rule)

    for device_id, rules in per_device_rules.items():
        if device_matches(
            rules, canonical_org=canonical_org, content_tags=content_tags
        ):
            matched.add(device_id)

    return sorted(matched)
