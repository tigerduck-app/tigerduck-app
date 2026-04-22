"""AsyncIOScheduler lifecycle tied to FastAPI's lifespan.

One scheduler per app instance. `max_instances=1` and `coalesce=True` on
the tick job prevent overlapping runs when a tick occasionally takes
longer than the interval — better to skip than double-send.
"""

from __future__ import annotations

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from server.bulletins import jobs as bulletin_jobs
from server.bulletins.llm.base import LLMProvider
from server.bulletins.llm.openai_compat import OpenAICompatibleProvider
from server.config import Settings
from server.push.apns_client import PushSender
from server.scheduler.dispatcher import dispatch_due_pushes


def build_llm_provider(settings: Settings) -> LLMProvider:
    return OpenAICompatibleProvider(
        base_url=settings.llm_base_url,
        api_key=settings.llm_api_key,
        model=settings.llm_model,
        timeout_seconds=settings.llm_timeout_seconds,
        max_retries=settings.llm_max_retries,
        temperature=settings.llm_temperature,
    )


def build_scheduler(
    session_factory: async_sessionmaker[AsyncSession],
    sender: PushSender,
    settings: Settings,
    *,
    llm: LLMProvider | None = None,
) -> AsyncIOScheduler:
    """Wire APScheduler with the four TigerDuck jobs:

    * `dispatcher_tick` — existing PTS dispatcher (Live Activity).
    * `bulletin_scrape` — fetch NTUST bulletin list every 10 min.
    * `bulletin_process` — drain pending bulletins through the LLM every 60s.
    * `bulletin_dispatch` — fan out alert pushes every 60s.

    Passing `llm=None` (the default) builds the real OpenAI-compatible
    provider; tests inject `RecordingProvider` to stay offline.
    """
    scheduler = AsyncIOScheduler(timezone="UTC")
    llm_provider = llm if llm is not None else build_llm_provider(settings)

    async def pts_tick() -> None:
        await dispatch_due_pushes(session_factory, sender, settings)

    async def bulletin_scrape() -> None:
        await bulletin_jobs.scrape_job(session_factory, settings)

    async def bulletin_process() -> None:
        await bulletin_jobs.process_job(session_factory, settings, llm_provider)

    async def bulletin_dispatch() -> None:
        await bulletin_jobs.dispatch_job(session_factory, sender, settings)

    scheduler.add_job(
        pts_tick,
        trigger=IntervalTrigger(seconds=settings.scheduler_tick_seconds),
        id="dispatcher_tick",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=30,
        next_run_time=None,
    )
    scheduler.add_job(
        bulletin_scrape,
        trigger=IntervalTrigger(seconds=settings.bulletin_scrape_interval_seconds),
        id="bulletin_scrape",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=60,
        next_run_time=None,
    )
    scheduler.add_job(
        bulletin_process,
        trigger=IntervalTrigger(seconds=settings.bulletin_process_interval_seconds),
        id="bulletin_process",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=30,
        next_run_time=None,
    )
    scheduler.add_job(
        bulletin_dispatch,
        trigger=IntervalTrigger(seconds=settings.bulletin_dispatch_interval_seconds),
        id="bulletin_dispatch",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=30,
        next_run_time=None,
    )
    return scheduler
