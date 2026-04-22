"""Shared-secret auth for write endpoints.

Checked via the `X-Push-Token` header. If `settings.api_shared_secret` is
unset (empty string) the dependency is a no-op — convenient for local dev
and the test suite. Production must set ``TIGERDUCK_API_SHARED_SECRET``.
"""

from __future__ import annotations

import secrets

from fastapi import Header, HTTPException, Request, status


async def require_shared_secret(
    request: Request,
    x_push_token: str | None = Header(default=None, alias="X-Push-Token"),
) -> None:
    expected: str = request.app.state.settings.api_shared_secret
    if not expected:
        return  # auth disabled (dev/test default)
    if x_push_token is None or not secrets.compare_digest(x_push_token, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid or missing X-Push-Token",
        )
