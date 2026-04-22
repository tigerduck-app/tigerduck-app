"""AsyncIOScheduler lifecycle tied to FastAPI's lifespan.

One scheduler per app instance. `max_instances=1` and `coalesce=True` on
the tick job prevent overlapping runs when a tick occasionally takes
longer than the interval — better to skip than double-send.
"""

from __future__ import annotations

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from server.config import Settings
from server.push.apns_client import PushSender
from server.scheduler.dispatcher import dispatch_due_pushes


def build_scheduler(
    session_factory: async_sessionmaker[AsyncSession],
    sender: PushSender,
    settings: Settings,
) -> AsyncIOScheduler:
    scheduler = AsyncIOScheduler(timezone="UTC")

    async def tick() -> None:
        await dispatch_due_pushes(session_factory, sender, settings)

    scheduler.add_job(
        tick,
        trigger=IntervalTrigger(seconds=settings.scheduler_tick_seconds),
        id="dispatcher_tick",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=30,
        next_run_time=None,
    )
    return scheduler
