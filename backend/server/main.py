"""FastAPI entrypoint for the push notification server."""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import AsyncIterator

import structlog
from fastapi import FastAPI

from server.config import Settings, get_settings
from server.logging_setup import configure as configure_logging

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
    # DB engine, scheduler, APNs client will be wired in later checkpoints.
    yield
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

    return app


app = create_app()
