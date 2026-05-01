"""FastAPI entrypoint for the push notification server."""

from __future__ import annotations

# Relax OpenSSL 3 strict cert parsing before any httpx client loads — see
# server/_ssl_compat.py for the full why.
from server import _ssl_compat  # noqa: F401, E402

import asyncio  # noqa: E402
import time  # noqa: E402
from contextlib import asynccontextmanager  # noqa: E402
from typing import AsyncIterator  # noqa: E402

import httpx  # noqa: E402
import structlog  # noqa: E402
from fastapi import FastAPI  # noqa: E402

from server.config import Settings, get_settings
from server.db import build_engine, build_session_factory
from server.logging_setup import configure as configure_logging
from server.push.router import build_router
from server.routes import bulletins as bulletins_routes
from server.routes import debug as debug_routes
from server.routes import devices as devices_routes
from server.routes import live_activities as live_activities_routes
from server.routes import schedule as schedule_routes
from server.scheduler.runtime import build_scheduler

logger = structlog.get_logger(__name__)


# How long startup is willing to wait for the LLM endpoint. 60s comfortably
# covers a cold `llama-server` load of Gemma-4 E4B Q4 on Apple Silicon.
_LLM_READY_WAIT_SECONDS = 60.0
_LLM_READY_POLL_INTERVAL = 2.0


async def _wait_for_llm(settings: Settings) -> bool:
    """Poll the LLM /models endpoint until 200 or the wait budget runs out.

    Returns True if the LLM answered in time, False otherwise.

    Intentionally NON-blocking: on failure we log a warning and let the
    server finish booting. Rationale:

    * Read endpoints (`GET /v2/bulletins/...`) don't need the LLM at all.
    * The scheduler's `bulletin_process` job has its own retry/backoff,
      so transient LLM downtime self-heals without server restart.
    * launchd / Docker supervisor would otherwise pin-pong the API
      process if we hard-failed startup when llama-server is slow to load.
    """
    base = settings.llm_base_url.rstrip("/")
    url = f"{base}/models"
    auth = {"Authorization": f"Bearer {settings.llm_api_key}"}
    deadline = time.monotonic() + _LLM_READY_WAIT_SECONDS
    attempt = 0
    async with httpx.AsyncClient(timeout=3.0) as client:
        while time.monotonic() < deadline:
            attempt += 1
            try:
                r = await client.get(url, headers=auth)
                if r.status_code < 400:
                    logger.info(
                        "llm.ready",
                        base_url=settings.llm_base_url,
                        attempt=attempt,
                    )
                    return True
            except httpx.HTTPError:
                pass
            await asyncio.sleep(_LLM_READY_POLL_INTERVAL)
    logger.warning(
        "llm.not_ready_after_wait",
        base_url=settings.llm_base_url,
        waited_seconds=_LLM_READY_WAIT_SECONDS,
        attempts=attempt,
    )
    return False


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings: Settings = app.state.settings
    logger.info(
        "server.startup",
        env=settings.env,
        api_base_path=settings.api_base_path,
        apns_env=settings.apns_env,
        apns_topic=settings.apns_topic_live_activity,
    )

    await _wait_for_llm(settings)

    engine = build_engine(settings)
    session_factory = build_session_factory(engine)
    router = build_router(settings)
    scheduler = build_scheduler(session_factory, router, settings)

    app.state.engine = engine
    app.state.session_factory = session_factory
    app.state.router = router
    # Keep the legacy `sender` attribute pointing at the APNs sender so any
    # tooling that read `app.state.sender` for Live-Activity / iOS paths
    # keeps working without a downstream change.
    app.state.sender = router.apple
    app.state.scheduler = scheduler
    app.state.settings = settings

    scheduler.start()
    logger.info("scheduler.started", tick_seconds=settings.scheduler_tick_seconds)

    try:
        yield
    finally:
        scheduler.shutdown(wait=False)
        await router.close()
        await engine.dispose()
        logger.info("server.shutdown")


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings)

    app = FastAPI(
        title="TigerDuck Push Server",
        version="0.1.0",
        lifespan=lifespan,
    )
    app.state.settings = settings

    @app.get("/health", tags=["meta"])
    async def health() -> dict[str, str]:
        return {"status": "ok", "env": settings.env}

    @app.get(f"{settings.api_base_path}/ping", tags=["meta"])
    async def ping() -> dict[str, str]:
        return {"pong": "tigerduck"}

    _mount_api(app, settings.api_base_path)
    for legacy in settings.api_legacy_base_paths:
        _mount_api(app, legacy)

    if settings.api_legacy_base_paths:
        _install_deprecation_middleware(
            app,
            current=settings.api_base_path,
            legacy_paths=tuple(settings.api_legacy_base_paths),
            sunset=settings.api_legacy_sunset,
        )

    return app


def _mount_api(app: FastAPI, prefix: str) -> None:
    # ping is registered per-prefix so the deprecation middleware stamps
    # /v1/ping responses just like the routed endpoints.
    async def ping() -> dict[str, str]:
        return {"pong": "tigerduck"}

    app.add_api_route(f"{prefix}/ping", ping, methods=["GET"], tags=["meta"])
    app.include_router(devices_routes.router, prefix=prefix)
    app.include_router(live_activities_routes.router, prefix=prefix)
    app.include_router(schedule_routes.router, prefix=prefix)
    app.include_router(debug_routes.router, prefix=prefix)
    app.include_router(bulletins_routes.router, prefix=prefix)
    app.include_router(bulletins_routes.device_router, prefix=prefix)


def _install_deprecation_middleware(
    app: FastAPI,
    *,
    current: str,
    legacy_paths: tuple[str, ...],
    sunset: str,
) -> None:
    """Stamp RFC 8594 Deprecation + successor-version Link on legacy responses."""

    @app.middleware("http")
    async def _deprecation_headers(request, call_next):
        response = await call_next(request)
        path = request.url.path
        for legacy in legacy_paths:
            if path == legacy or path.startswith(f"{legacy}/"):
                response.headers["Deprecation"] = "true"
                successor = current + path[len(legacy):]
                response.headers["Link"] = (
                    f'<{successor}>; rel="successor-version"'
                )
                if sunset:
                    response.headers["Sunset"] = sunset
                break
        return response


app = create_app()
