"""Periodic cleanup for Live Activity update-token rows.

The dispatcher only moves rows between states — it never deletes them. Over
time, ended / failed / cancelled rows accumulate for every Live Activity a
device has ever run. This job prunes terminal rows whose `updated_at` sits
outside the retention window so the table stays bounded.

Rows with `status=active` are intentionally left alone: they still reference
a running Live Activity, and a stale active row will either be replaced by
the client's next registration (ON CONFLICT DO UPDATE) or cascade-deleted
when the owning device is unregistered.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import structlog
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from server.config import Settings
from server.models import LiveActivityTokenStatus, LiveActivityUpdateToken

logger = structlog.get_logger(__name__)


_TERMINAL_STATES = (
    LiveActivityTokenStatus.ended.value,
    LiveActivityTokenStatus.failed.value,
    LiveActivityTokenStatus.cancelled.value,
)


async def prune_terminal_activity_tokens(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> int:
    """Delete terminal-state update-token rows older than the retention
    window. Returns the number of rows deleted for observability."""
    cutoff = datetime.now(timezone.utc) - timedelta(
        days=settings.live_activity_token_retention_days
    )
    async with session_factory() as session:
        result = await session.execute(
            delete(LiveActivityUpdateToken).where(
                LiveActivityUpdateToken.status.in_(_TERMINAL_STATES),
                LiveActivityUpdateToken.updated_at < cutoff,
            )
        )
        await session.commit()
    deleted = result.rowcount or 0
    logger.info(
        "live_activity_tokens.retention.done",
        deleted=deleted,
        cutoff=cutoff.isoformat(),
        retention_days=settings.live_activity_token_retention_days,
    )
    return deleted
