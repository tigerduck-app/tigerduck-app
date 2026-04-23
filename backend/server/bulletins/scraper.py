"""Scrape the NTUST bulletin list page and parse its table.

The list page (`https://bulletin.ntust.edu.tw/p/403-1045-1391-1.php`) has a
single `table.listTB` with three columns: date, publisher, title (the title
cell wraps an `<a>` with the canonical detail URL). We extract one
`ListRow` per `<tr>` and let downstream stages decide which ones are new.

Public entrypoint: `fetch_list(url, client) -> list[ListRow]`. Parsing is a
pure function (`parse_list_html`) so tests can feed in canned HTML without
hitting the network.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime, time, timezone

import httpx
import structlog
from selectolax.parser import HTMLParser

logger = structlog.get_logger(__name__)


# Bulletin detail URLs look like:
#   https://bulletin.ntust.edu.tw/p/{prefix}-1045-{id},{suffix}.php?Lang=...
# We anchor on `-1045-` to avoid collisions with future URL shape tweaks
# (e.g. a different subsite code in `{prefix}`).
_EXTERNAL_ID_RE = re.compile(r"-1045-(\d+)")


@dataclass(frozen=True)
class ListRow:
    """One entry from the bulletin list table — everything available without
    fetching the detail page."""

    external_id: str
    title: str
    source_url: str
    raw_publisher: str
    posted_at: datetime | None


def extract_external_id(url: str) -> str | None:
    match = _EXTERNAL_ID_RE.search(url)
    return match.group(1) if match else None


def _parse_posted_at(raw: str) -> datetime | None:
    raw = raw.strip()
    if not raw:
        return None
    try:
        d: date = datetime.strptime(raw, "%Y-%m-%d").date()
    except ValueError:
        return None
    # The list page shows date-only. Treat 00:00 Asia/Taipei as the posting
    # instant — good enough for ordering and for the "stale for N cycles"
    # check, and avoids inventing a false precision.
    return datetime.combine(d, time(), tzinfo=timezone.utc)


def parse_list_html(html: str) -> list[ListRow]:
    tree = HTMLParser(html)
    table = tree.css_first("table.listTB")
    if table is None:
        logger.warning("bulletins.scraper.no_table_found")
        return []

    rows = table.css("tbody tr")
    if not rows:
        # Older Plone layouts don't emit an explicit <tbody>.
        all_rows = table.css("tr")
        rows = all_rows[1:] if all_rows else []

    out: list[ListRow] = []
    for tr in rows:
        cells = tr.css("td")
        if len(cells) < 3:
            continue

        date_cell, pub_cell, title_cell = cells[0], cells[1], cells[2]
        anchor = title_cell.css_first("a")
        if anchor is None:
            continue

        href = anchor.attributes.get("href") or ""
        external_id = extract_external_id(href)
        if external_id is None:
            logger.warning("bulletins.scraper.skipped_unparseable_href", href=href)
            continue

        title = anchor.text(strip=True)
        if not title:
            continue

        out.append(
            ListRow(
                external_id=external_id,
                title=title,
                source_url=href,
                raw_publisher=pub_cell.text(strip=True),
                posted_at=_parse_posted_at(date_cell.text(strip=True)),
            )
        )

    return out


async def fetch_list(
    url: str,
    client: httpx.AsyncClient,
    *,
    timeout_seconds: float = 15.0,
) -> list[ListRow]:
    """GET the list page and return parsed rows. Raises on HTTP errors so
    the calling scheduler tick can mark the run failed and retry later."""
    response = await client.get(url, timeout=timeout_seconds)
    response.raise_for_status()
    rows = parse_list_html(response.text)
    logger.info(
        "bulletins.scraper.fetched_list",
        url=url,
        status=response.status_code,
        row_count=len(rows),
    )
    return rows
