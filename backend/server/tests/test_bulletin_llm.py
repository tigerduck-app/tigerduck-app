"""Tests for the LLM provider layer.

We don't hit a real model here — a mocked `httpx.AsyncClient` replays
canned responses so we can exercise the schema parsing, retry, and error
paths without depending on Mac mini availability. Live integration against
llama.cpp / Gemini is left for manual smoke testing once those endpoints
are online.
"""

from __future__ import annotations

import json

import httpx
import pytest

from server.bulletins.llm.base import BulletinMetadata, LLMError, LLMProvider
from server.bulletins.llm.openai_compat import (
    OpenAICompatibleProvider,
    RecordingProvider,
    _backoff_seconds,
    _parse_response,
)
from server.bulletins.llm.prompts import RESPONSE_SCHEMA, SYSTEM_PROMPT
from server.bulletins.taxonomy import CanonicalOrg, ContentTag, Importance

_async = pytest.mark.asyncio(loop_scope="session")


# ---- Schema / taxonomy alignment -------------------------------------------


def test_schema_enum_matches_taxonomy() -> None:
    org_enum = RESPONSE_SCHEMA["properties"]["canonical_org"]["enum"]
    tag_enum = RESPONSE_SCHEMA["properties"]["content_tags"]["items"]["enum"]
    importance_enum = RESPONSE_SCHEMA["properties"]["importance"]["enum"]

    assert set(org_enum) == {o.value for o in CanonicalOrg}
    assert set(tag_enum) == {t.value for t in ContentTag}
    assert set(importance_enum) == {i.value for i in Importance}


def test_system_prompt_mentions_free_meal_guard() -> None:
    # Regression guard: the tag was added late; make sure the prompt still
    # carries the "free food only" rule so the model doesn't over-tag.
    assert "free_meal" in SYSTEM_PROMPT
    assert "FREE" in SYSTEM_PROMPT


# ---- Response parsing ------------------------------------------------------


def _good_payload() -> dict:
    return {
        "canonical_org": CanonicalOrg.student_affairs.value,
        "content_tags": [
            ContentTag.scholarship.value,
            ContentTag.important.value,
        ],
        "summary": "學務處發放新獎學金，請同學盡速申請",
        "body_clean": "## 重點\n- 申請期限 4/30\n- 至生輔組領取",
        "importance": Importance.high.value,
    }


def test_parse_response_happy_path() -> None:
    meta = _parse_response(json.dumps(_good_payload()))
    assert meta.canonical_org is CanonicalOrg.student_affairs
    assert set(meta.content_tags) == {ContentTag.scholarship, ContentTag.important}
    assert meta.importance is Importance.high
    assert meta.summary.startswith("學務處")
    assert "4/30" in meta.body_clean


def test_parse_response_caps_summary_to_60_chars() -> None:
    payload = _good_payload()
    payload["summary"] = "A" * 120
    meta = _parse_response(json.dumps(payload))
    assert len(meta.summary) == 60


def test_parse_response_rejects_unknown_org() -> None:
    payload = _good_payload()
    payload["canonical_org"] = "not_a_real_org"
    with pytest.raises(LLMError):
        _parse_response(json.dumps(payload))


def test_parse_response_rejects_unknown_tag() -> None:
    payload = _good_payload()
    payload["content_tags"] = ["ghost_tag"]
    with pytest.raises(LLMError):
        _parse_response(json.dumps(payload))


def test_parse_response_rejects_empty_summary() -> None:
    payload = _good_payload()
    payload["summary"] = ""
    with pytest.raises(LLMError):
        _parse_response(json.dumps(payload))


def test_parse_response_rejects_bad_json() -> None:
    with pytest.raises(LLMError):
        _parse_response("not json {{{")


# ---- Backoff ---------------------------------------------------------------


def test_backoff_is_monotonic_and_capped() -> None:
    seq = [_backoff_seconds(i) for i in range(6)]
    assert seq == sorted(seq)
    assert max(seq) <= 8.0


# ---- Recording provider ----------------------------------------------------


@_async
async def test_recording_provider_conforms_to_protocol() -> None:
    provider = RecordingProvider(
        BulletinMetadata(canonical_org=CanonicalOrg.other, summary="x", body_clean="x")
    )
    assert isinstance(provider, LLMProvider)

    meta = await provider.classify(
        title="hello", raw_publisher="test", body_md="body"
    )
    assert meta.canonical_org is CanonicalOrg.other
    assert provider.calls == [
        {"title": "hello", "raw_publisher": "test", "body_md": "body"}
    ]


# ---- OpenAICompatibleProvider over mock httpx ------------------------------


class _MockTransport(httpx.AsyncBaseTransport):
    def __init__(self, responses: list[httpx.Response]) -> None:
        self._responses = list(responses)
        self.received: list[dict] = []

    async def handle_async_request(
        self, request: httpx.Request
    ) -> httpx.Response:
        self.received.append(json.loads(request.content.decode("utf-8")))
        return self._responses.pop(0)


def _ok_response() -> httpx.Response:
    body = {
        "choices": [
            {"message": {"content": json.dumps(_good_payload())}}
        ]
    }
    return httpx.Response(200, json=body)


@_async
async def test_openai_provider_happy_path() -> None:
    transport = _MockTransport([_ok_response()])
    client = httpx.AsyncClient(transport=transport, base_url="http://mock")
    provider = OpenAICompatibleProvider(
        base_url="http://mock/v1",
        api_key="sk-test",
        model="test-model",
        client=client,
    )
    try:
        meta = await provider.classify(
            title="t", raw_publisher="A", body_md="b"
        )
    finally:
        await client.aclose()

    assert meta.canonical_org is CanonicalOrg.student_affairs
    sent = transport.received[0]
    assert sent["model"] == "test-model"
    assert sent["response_format"]["type"] == "json_schema"
    assert sent["messages"][0]["role"] == "system"


@_async
async def test_openai_provider_retries_then_succeeds() -> None:
    # First call returns 503, second succeeds
    transport = _MockTransport([httpx.Response(503), _ok_response()])
    client = httpx.AsyncClient(transport=transport, base_url="http://mock")
    provider = OpenAICompatibleProvider(
        base_url="http://mock/v1",
        api_key="sk-test",
        model="test-model",
        max_retries=2,
        client=client,
    )
    try:
        meta = await provider.classify(title="t", raw_publisher="A", body_md="b")
    finally:
        await client.aclose()
    assert meta.canonical_org is CanonicalOrg.student_affairs
    assert len(transport.received) == 2


@_async
async def test_openai_provider_raises_after_exhausting_retries() -> None:
    transport = _MockTransport(
        [httpx.Response(503), httpx.Response(503), httpx.Response(503)]
    )
    client = httpx.AsyncClient(transport=transport, base_url="http://mock")
    provider = OpenAICompatibleProvider(
        base_url="http://mock/v1",
        api_key="sk-test",
        model="test-model",
        max_retries=2,
        client=client,
    )
    try:
        with pytest.raises(LLMError):
            await provider.classify(title="t", raw_publisher="A", body_md="b")
    finally:
        await client.aclose()
    assert len(transport.received) == 3
