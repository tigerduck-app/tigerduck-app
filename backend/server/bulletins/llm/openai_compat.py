"""OpenAI-compatible LLM provider.

Works against anything that speaks the `/v1/chat/completions` wire format
with `response_format.json_schema` support: llama.cpp server, vLLM, Ollama's
OpenAI endpoint, and Gemini's OpenAI-compatibility layer (`v1beta/openai/`).

Switching deployments is purely a `base_url` / `model` / `api_key` change —
no code path lives per-vendor. That way we can keep serving classification
requests from a local gemma-4-e4b while still flipping to Gemini free-tier
if the Mac mini is down.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

import httpx
import structlog

from server.bulletins.llm.base import BulletinMetadata, LLMError, LLMProvider
from server.bulletins.llm.prompts import (
    RESPONSE_FORMAT,
    SYSTEM_PROMPT,
    build_user_prompt,
)
from server.bulletins.taxonomy import CanonicalOrg, ContentTag, Importance

logger = structlog.get_logger(__name__)


# 100K tokens of slack below the E4B 128K context. Bulletins are almost
# always < 5K chars; this ceiling is only here so a runaway page (giant
# attached regulation PDF converted to Markdown) can't blow up inference.
_MAX_BODY_CHARS = 100_000


def _truncate(body_md: str) -> tuple[str, bool]:
    if len(body_md) <= _MAX_BODY_CHARS:
        return body_md, False
    return body_md[:_MAX_BODY_CHARS], True


class OpenAICompatibleProvider:
    """Minimal OpenAI-compat chat client. No `openai` SDK dependency so we
    don't inherit its auth/retry assumptions; httpx gives us enough."""

    def __init__(
        self,
        *,
        base_url: str,
        api_key: str,
        model: str,
        timeout_seconds: float = 30.0,
        max_retries: int = 2,
        temperature: float = 0.2,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._model = model
        self._timeout_seconds = timeout_seconds
        self._max_retries = max_retries
        self._temperature = temperature
        self._owns_client = client is None
        self._client = client or httpx.AsyncClient(
            timeout=httpx.Timeout(timeout_seconds),
            headers={"User-Agent": "TigerDuckBot/0.1"},
        )

    async def classify(
        self,
        *,
        title: str,
        raw_publisher: str,
        body_md: str,
    ) -> BulletinMetadata:
        body, truncated = _truncate(body_md)
        if truncated:
            logger.warning(
                "bulletins.llm.body_truncated",
                title=title[:40],
                original_len=len(body_md),
                kept_len=_MAX_BODY_CHARS,
            )

        payload: dict[str, Any] = {
            "model": self._model,
            "temperature": self._temperature,
            "response_format": RESPONSE_FORMAT,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": build_user_prompt(
                        title=title,
                        raw_publisher=raw_publisher,
                        body_md=body,
                    ),
                },
            ],
        }

        last_error: Exception | None = None
        for attempt in range(self._max_retries + 1):
            try:
                return await self._once(payload)
            except (httpx.HTTPError, LLMError, json.JSONDecodeError) as exc:
                last_error = exc
                if attempt >= self._max_retries:
                    break
                await asyncio.sleep(_backoff_seconds(attempt))
                logger.warning(
                    "bulletins.llm.retry",
                    attempt=attempt + 1,
                    error=str(exc)[:200],
                )

        raise LLMError(
            f"classification failed after {self._max_retries + 1} attempts: {last_error}"
        )

    async def _once(self, payload: dict[str, Any]) -> BulletinMetadata:
        response = await self._client.post(
            f"{self._base_url}/chat/completions",
            headers={"Authorization": f"Bearer {self._api_key}"},
            json=payload,
        )
        response.raise_for_status()
        data = response.json()
        content = _extract_message_content(data)
        return _parse_response(content)

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()


def _backoff_seconds(attempt: int) -> float:
    """0.5s, 1s, 2s, ... capped at 8s. Attempt index is 0-based."""
    return min(8.0, 0.5 * (2**attempt))


def _extract_message_content(data: dict[str, Any]) -> str:
    try:
        return data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise LLMError(f"response missing choices[0].message.content: {data!r}") from exc


def _parse_response(content: str) -> BulletinMetadata:
    try:
        obj = json.loads(content)
    except json.JSONDecodeError as exc:
        raise LLMError(f"content was not valid JSON: {content[:200]}") from exc

    try:
        canonical_org = CanonicalOrg(obj["canonical_org"])
        importance = Importance(obj.get("importance", Importance.normal.value))
        content_tags = tuple(ContentTag(t) for t in obj.get("content_tags", []))
    except (KeyError, ValueError) as exc:
        raise LLMError(f"response failed enum validation: {obj!r}") from exc

    summary = str(obj.get("summary", "")).strip()
    body_clean = str(obj.get("body_clean", "")).strip()
    if not summary or not body_clean:
        raise LLMError(f"summary and body_clean must be non-empty: {obj!r}")

    # Keep summary below our hard cap — the prompt asks for 60 but models
    # occasionally overshoot. We truncate rather than retry since the payload
    # is good enough.
    return BulletinMetadata(
        canonical_org=canonical_org,
        content_tags=content_tags,
        summary=summary[:60],
        body_clean=body_clean,
        importance=importance,
    )


class RecordingProvider:
    """Test double — returns a fixed response and records calls."""

    def __init__(self, response: BulletinMetadata) -> None:
        self._response = response
        self.calls: list[dict[str, str]] = []

    async def classify(
        self,
        *,
        title: str,
        raw_publisher: str,
        body_md: str,
    ) -> BulletinMetadata:
        self.calls.append(
            {"title": title, "raw_publisher": raw_publisher, "body_md": body_md}
        )
        return self._response

    async def close(self) -> None:
        pass


# Module-level sanity: Protocol conformance at import time so a bad refactor
# doesn't pass tests silently. `runtime_checkable` makes this cheap.
assert isinstance(RecordingProvider(BulletinMetadata(canonical_org=CanonicalOrg.other)), LLMProvider)
