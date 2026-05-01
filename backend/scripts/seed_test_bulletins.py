"""Seed fake, already-classified bulletins for Android push smoke testing.

Inserts one bulletin per CanonicalOrg (16 rows), cycling ContentTags (so every
tag appears at least once across the batch) and Importance levels (low /
normal / high each appear). Rows go in with processing_state='processed' and
notified_at IS NULL, so the next dispatcher tick will fan them out to every
matching device. No LLM call is made.

Usage:
    cd backend
    uv run python scripts/seed_test_bulletins.py
    uv run python scripts/seed_test_bulletins.py --multi-tag   # also adds a row with several tags
    uv run python scripts/seed_test_bulletins.py --clear       # delete prior seeded rows first
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import delete

_BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(_BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(_BACKEND_DIR))

from server.bulletins.models import (  # noqa: E402
    Bulletin,
    BulletinProcessingState,
)
from server.bulletins.taxonomy import (  # noqa: E402
    CanonicalOrg,
    ContentTag,
    Importance,
    ORG_LABELS,
    TAG_LABELS,
)
from server.config import Settings  # noqa: E402
from server.db import build_engine, build_session_factory  # noqa: E402

SOURCE = "test_seed"
EXTERNAL_ID_PREFIX = "seed-"


def _build_rows(now: datetime, multi_tag: bool) -> list[dict]:
    orgs = list(CanonicalOrg)
    tags = list(ContentTag)
    importances = [Importance.low, Importance.normal, Importance.high]

    rows: list[dict] = []
    for i, org in enumerate(orgs):
        tag = tags[i % len(tags)]
        importance = importances[i % len(importances)]
        org_label = ORG_LABELS[org]
        tag_label = TAG_LABELS[tag]
        title = f"[測試] {org_label}・{tag_label}・{importance.value}"
        summary = (
            f"測試公告：org={org.value} tag={tag.value} "
            f"importance={importance.value}（自動產生，僅供推播煙霧測試）"
        )
        rows.append(
            {
                "source": SOURCE,
                "external_id": f"{EXTERNAL_ID_PREFIX}{i:02d}-{org.value}",
                "source_url": f"https://example.invalid/seed/{i:02d}",
                "raw_publisher": org_label,
                "canonical_org": org.value,
                "content_tags": [tag.value],
                "summary": summary,
                "body_clean": summary,
                "body_md": summary,
                "importance": importance.value,
                "title": title,
                "title_clean": title,
                "posted_at": now,
                "first_seen_at": now,
                "last_seen_at": now,
                "processing_state": BulletinProcessingState.processed.value,
                "processing_attempts": 0,
                "is_deleted": False,
                "notified_at": None,
            }
        )

    # Confirm every tag appeared. With 16 orgs vs 13 tags this is guaranteed,
    # but assert so a future taxonomy edit can't silently drop coverage.
    seen_tags = {row["content_tags"][0] for row in rows}
    missing = {t.value for t in ContentTag} - seen_tags
    assert not missing, f"tags missing from seed: {missing}"

    if multi_tag:
        all_tags = [t.value for t in ContentTag]
        rows.append(
            {
                "source": SOURCE,
                "external_id": f"{EXTERNAL_ID_PREFIX}99-multitag",
                "source_url": "https://example.invalid/seed/99",
                "raw_publisher": ORG_LABELS[CanonicalOrg.other],
                "canonical_org": CanonicalOrg.other.value,
                "content_tags": all_tags,
                "summary": "測試公告：所有 tag 同時掛上，驗證多標籤渲染。",
                "body_clean": "測試公告：所有 tag 同時掛上。",
                "body_md": "測試公告：所有 tag 同時掛上。",
                "importance": Importance.high.value,
                "title": "[測試] 多標籤公告",
                "title_clean": "[測試] 多標籤公告",
                "posted_at": now,
                "first_seen_at": now,
                "last_seen_at": now,
                "processing_state": BulletinProcessingState.processed.value,
                "processing_attempts": 0,
                "is_deleted": False,
                "notified_at": None,
            }
        )
    return rows


async def main_async(args: argparse.Namespace) -> int:
    settings = Settings()
    engine = build_engine(settings)
    session_factory = build_session_factory(engine)
    now = datetime.now(timezone.utc)

    try:
        if args.clear:
            async with session_factory() as session:
                result = await session.execute(
                    delete(Bulletin).where(Bulletin.source == SOURCE)
                )
                await session.commit()
            print(f"[clear] deleted {result.rowcount or 0} prior seeded rows")

        rows = _build_rows(now, multi_tag=args.multi_tag)
        async with session_factory() as session:
            session.add_all(Bulletin(**r) for r in rows)
            await session.commit()
        print(f"[seed] inserted {len(rows)} bulletins (source={SOURCE!r})")
        print(
            "[seed] dispatcher will fan these out on its next tick "
            f"({settings.bulletin_dispatch_interval_seconds}s). "
            "Make sure a device is registered with matching subscriptions "
            "(empty orgs+tags = wildcard)."
        )
    finally:
        await engine.dispose()
    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument(
        "--clear",
        action="store_true",
        help=f"delete prior rows where source='{SOURCE}' before inserting",
    )
    p.add_argument(
        "--multi-tag",
        action="store_true",
        help="also insert one extra bulletin carrying every tag at once",
    )
    return p


def main() -> int:
    args = build_arg_parser().parse_args()
    try:
        return asyncio.run(main_async(args))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
