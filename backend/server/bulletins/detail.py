"""Fetch a bulletin detail page and extract clean markdown via trafilatura."""

from __future__ import annotations

from dataclasses import dataclass

import httpx
import structlog
import trafilatura

logger = structlog.get_logger(__name__)


@dataclass(frozen=True)
class DetailContent:
    body_md: str
    # Raw HTML is kept around only for debugging scrape failures — we don't
    # persist it to the DB (doubles storage for no gain once trafilatura
    # is trusted). Callers can drop it after use.
    raw_html: str


def extract_markdown(html: str) -> str | None:
    """Pure-function wrapper around trafilatura so tests don't hit the network."""
    return trafilatura.extract(
        html,
        output_format="markdown",
        include_links=True,
        include_tables=True,
        include_images=False,
        # Bulletins are Taiwanese Chinese; disable the news-focused heuristics
        # that sometimes trim announcement blocks as "boilerplate".
        favor_recall=True,
    )


async def fetch_detail(
    url: str,
    client: httpx.AsyncClient,
    *,
    timeout_seconds: float = 15.0,
) -> DetailContent | None:
    """Fetch the detail page and return clean markdown. Returns None when
    trafilatura can't find a body — common for redirect-only stubs — so the
    caller can mark the bulletin failed instead of storing an empty body."""
    response = await client.get(url, timeout=timeout_seconds)
    response.raise_for_status()
    html = response.text

    md = extract_markdown(html)
    if md is None or not md.strip():
        logger.warning("bulletins.detail.empty_extract", url=url)
        return None

    return DetailContent(body_md=md, raw_html=html)
