"""FastAPI entrypoint for the push notification server."""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import AsyncIterator

import structlog
from fastapi import FastAPI

from server.config import Settings, get_settings
from server.db import build_engine, build_session_factory
from server.logging_setup import configure as configure_logging
from server.routes import devices as devices_routes
from server.routes import schedule as schedule_routes

logger = structlog.get_logger(__name__)


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

    engine = build_engine(settings)
    app.state.engine = engine
    app.state.session_factory = build_session_factory(engine)

    try:
        yield
    finally:
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

    app.include_router(devices_routes.router, prefix=settings.api_base_path)
    app.include_router(schedule_routes.router, prefix=settings.api_base_path)

    return app


app = create_app()
