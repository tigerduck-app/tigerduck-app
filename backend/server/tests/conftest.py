"""Shared fixtures: isolated Postgres schema per test session + httpx AsyncClient."""

from __future__ import annotations

import re
from collections.abc import AsyncIterator

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import AsyncEngine

from sqlalchemy.ext.asyncio import create_async_engine

from server.config import Settings
from server.db import Base, build_engine, build_session_factory
from server.main import create_app

# PostgreSQL identifiers cannot be passed as bind params in DDL, so we must
# interpolate. Enforce a strict whitelist instead to neutralise SQL injection
# if `db_name` ever becomes configurable.
_SAFE_IDENT = re.compile(r"[a-z_][a-z0-9_]{0,62}")

# Default admin database to connect to when issuing DROP/CREATE DATABASE
# against the test DB. PostgreSQL forbids DROPping the DB you are connected
# to, so we attach to a separate maintenance DB that we assume already
# exists on the dev instance.
_ADMIN_DB = "tigerduck"


def _assert_safe_ident(db_name: str) -> None:
    if not _SAFE_IDENT.fullmatch(db_name):
        raise ValueError(f"Unsafe db identifier: {db_name!r}")


def _admin_url(settings: Settings) -> str:
    """Derive the admin-DB URL from test_settings so credentials stay in one place."""
    # `str(url)` masks passwords as `***`, which asyncpg then treats as the
    # literal password and fails with InvalidPasswordError. Render explicitly
    # without masking so the real credential reaches the driver.
    return make_url(settings.database_url).set(database=_ADMIN_DB).render_as_string(
        hide_password=False
    )


async def _drop_create_db(admin_url: str, db_name: str) -> None:
    _assert_safe_ident(db_name)
    admin = create_async_engine(admin_url, isolation_level="AUTOCOMMIT")
    async with admin.connect() as conn:
        await conn.exec_driver_sql(f"DROP DATABASE IF EXISTS {db_name}")
        await conn.exec_driver_sql(f"CREATE DATABASE {db_name}")
    await admin.dispose()


async def _drop_db(admin_url: str, db_name: str) -> None:
    _assert_safe_ident(db_name)
    admin = create_async_engine(admin_url, isolation_level="AUTOCOMMIT")
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
    admin_url = _admin_url(test_settings)
    test_db = make_url(test_settings.database_url).database
    assert test_db is not None, "test_settings.database_url is missing a database name"

    await _drop_create_db(admin_url, test_db)
    engine = build_engine(test_settings)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    yield engine

    await engine.dispose()
    await _drop_db(admin_url, test_db)


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
