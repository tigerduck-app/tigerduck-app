"""Legacy /v1 prefix is mounted alongside /v2 with deprecation headers."""

from __future__ import annotations

import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio(loop_scope="session")


async def test_v1_ping_works_and_is_deprecated(client: AsyncClient):
    response = await client.get("/v1/ping")
    assert response.status_code == 200
    assert response.json() == {"pong": "tigerduck"}
    assert response.headers.get("Deprecation") == "true"
    assert response.headers.get("Link") == '</v2/ping>; rel="successor-version"'


async def test_v1_register_without_platform_defaults_to_apple(client: AsyncClient):
    # Pre-platform-header iOS clients omit the field; schema default fills it.
    payload = {
        "user_id": "legacy-user",
        "device_id": "legacy-device",
        "pts_token_hex": "ab" * 32,
        "bundle_id": "org.ntust.app.TigerDuck",
        "attrs_type": "TigerDuckActivityAttributes",
        "apns_env": "development",
    }
    response = await client.post("/v1/devices/register", json=payload)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["platform"] == "apple"
    assert response.headers.get("Deprecation") == "true"
    assert (
        response.headers.get("Link")
        == '</v2/devices/register>; rel="successor-version"'
    )


async def test_v2_responses_have_no_deprecation_headers(client: AsyncClient):
    response = await client.get("/v2/ping")
    assert response.status_code == 200
    assert "Deprecation" not in response.headers
    assert "Link" not in response.headers
