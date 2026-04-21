"""Device registration endpoint tests."""

from __future__ import annotations

import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio(loop_scope="session")


async def _register_payload(**overrides) -> dict:
    base = {
        "user_id": "user-abc",
        "device_id": "device-xyz",
        "pts_token_hex": "a1b2c3" * 10,
        "bundle_id": "org.ntust.app.TigerDuck",
        "attrs_type": "TigerDuckActivityAttributes",
        "apns_env": "development",
    }
    base.update(overrides)
    return base


async def test_register_device_creates_row(client: AsyncClient):
    payload = await _register_payload()
    response = await client.post("/v1/devices/register", json=payload)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["device_id"] == "device-xyz"
    assert body["user_id"] == "user-abc"
    assert "registered_at" in body


async def test_register_is_idempotent_upsert(client: AsyncClient):
    p1 = await _register_payload(pts_token_hex="aa" * 32)
    p2 = await _register_payload(pts_token_hex="bb" * 32)

    r1 = await client.post("/v1/devices/register", json=p1)
    assert r1.status_code == 200

    r2 = await client.post("/v1/devices/register", json=p2)
    assert r2.status_code == 200

    got = await client.get("/v1/devices/device-xyz")
    assert got.status_code == 200


async def test_unregister_device_cascade(client: AsyncClient):
    payload = await _register_payload()
    await client.post("/v1/devices/register", json=payload)

    unreg = await client.post(
        "/v1/devices/unregister",
        json={"device_id": "device-xyz"},
    )
    assert unreg.status_code == 204

    got = await client.get("/v1/devices/device-xyz")
    assert got.status_code == 404


async def test_register_rejects_invalid_apns_env(client: AsyncClient):
    payload = await _register_payload(apns_env="staging")
    response = await client.post("/v1/devices/register", json=payload)
    assert response.status_code == 422
