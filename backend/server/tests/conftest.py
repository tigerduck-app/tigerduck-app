"""Shared fixtures: isolated Postgres schema per test session + httpx AsyncClient."""

from __future__ import annotations

import re
from collections.abc import AsyncIterator

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from sqlalchemy.ext.asyncio import create_async_engine

from server.config import Settings
from server.db import Base, build_engine, build_session_factory
from server.main import create_app

# PostgreSQL identifiers cannot be passed as bind params in DDL, so we must
# interpolate. Enforce a strict whitelist instead to neutralise SQL injection
# if `db_name` ever becomes configurable.
_SAFE_IDENT = re.compile(r"[a-z_][a-z0-9_]{0,62}")


def _assert_safe_ident(db_name: str) -> None:
    if not _SAFE_IDENT.fullmatch(db_name):
        raise ValueError(f"Unsafe db identifier: {db_name!r}")


async def _drop_create_db(db_name: str) -> None:
    _assert_safe_ident(db_name)
    admin = create_async_engine(
        "postgresql+asyncpg://tigerduck:tigerduck@localhost:5432/tigerduck",
        isolation_level="AUTOCOMMIT",
    )
    async with admin.connect() as conn:
        await conn.exec_driver_sql(f"DROP DATABASE IF EXISTS {db_name}")
        await conn.exec_driver_sql(f"CREATE DATABASE {db_name}")
    await admin.dispose()


async def _drop_db(db_name: str) -> None:
    _assert_safe_ident(db_name)
    admin = create_async_engine(
        "postgresql+asyncpg://tigerduck:tigerduck@localhost:5432/tigerduck",
        isolation_level="AUTOCOMMIT",
    )
    async with admin.connect() as conn:
        await conn.exec_driver_sql(f"DROP DATABASE IF EXISTS {db_name}")
    await admin.dispose()


@pytest.fixture(scope="session")
def test_settings() -> Settings:
    # Override DB to the same dev Postgres, but drop+recreate schema per session.
    # `scheduler_tick_seconds=99999` neuters the background APScheduler job
    # that ASGITransport starts via the lifespan handler — otherwise the
    # dispatcher could mark test rows `sent` and make assertions flaky.
    return Settings(
        env="development",
        database_url="postgresql+asyncpg://tigerduck:tigerduck@localhost:5432/tigerduck_test",
        apns_env="development",
        scheduler_tick_seconds=99999,
        api_shared_secret="",
    )


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def prepared_engine(test_settings: Settings) -> AsyncIterator[AsyncEngine]:
    await _drop_create_db("tigerduck_test")
    engine = build_engine(test_settings)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    yield engine

    await engine.dispose()
    await _drop_db("tigerduck_test")


@pytest_asyncio.fixture(loop_scope="session")
async def client(
    test_settings: Settings,
    prepared_engine: AsyncEngine,
) -> AsyncIterator[AsyncClient]:
    # Fresh tables for every test
    async with prepared_engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)

    app = create_app(test_settings)

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        # ASGITransport DOES invoke lifespan, so the app now owns its own
        # engine + session_factory. Swap in our prepared engine *after* the
        # transport context enters so our shared DB survives per-test cycles.
        app.state.engine = prepared_engine
        app.state.session_factory = build_session_factory(prepared_engine)
        yield ac
