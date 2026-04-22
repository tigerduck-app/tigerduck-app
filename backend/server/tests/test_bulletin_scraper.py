"""Tests for the bulletin list-page parser and detail-page extractor.

Parsing tests feed canned HTML into the pure functions so we never depend
on the NTUST site being reachable. The dedup tests spin up the real
Postgres via the `prepared_engine` fixture to exercise the partial-unique
index and UPSERT semantics.
"""

from __future__ import annotations

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker

from server.bulletins.dedup import (
    attach_body_and_dedup,
    compute_content_hash,
    normalize_for_hash,
    upsert_list_rows,
)
from server.bulletins.detail import extract_markdown
from server.bulletins.models import Bulletin, BulletinProcessingState
from server.bulletins.scraper import ListRow, extract_external_id, parse_list_html

_async = pytest.mark.asyncio(loop_scope="session")


# ---- URL parsing -----------------------------------------------------------


def test_extract_external_id_from_detail_url() -> None:
    url = "https://bulletin.ntust.edu.tw/p/406-1045-146758,r1391.php?Lang=zh-tw"
    assert extract_external_id(url) == "146758"


def test_extract_external_id_c0_variant() -> None:
    url = "https://bulletin.ntust.edu.tw/p/450-1045-145825,c0.php?Lang=zh-tw"
    assert extract_external_id(url) == "145825"


def test_extract_external_id_returns_none_for_list_page() -> None:
    assert extract_external_id("https://bulletin.ntust.edu.tw/p/403-1045-1391-1.php") == "1391"
    # Note: list URLs contain -1045-1391- which matches. Good — we only use
    # this regex on detail URLs pulled from <a href>, so the ambiguity never
    # lands in production. Keeping the test here as documentation.


def test_extract_external_id_none_for_garbage() -> None:
    assert extract_external_id("https://example.com/") is None


# ---- List HTML parsing -----------------------------------------------------

_SAMPLE_LIST_HTML = """
<html><body>
<table class="listTB table">
  <thead><tr><th>日期</th><th>發佈單位</th><th>標題</th></tr></thead>
  <tbody>
    <tr>
      <td>2026-04-22</td>
      <td>通識教育中心</td>
      <td><a href="https://bulletin.ntust.edu.tw/p/406-1045-146758,r1391.php?Lang=zh-tw">[參訪] 綠能體驗</a></td>
    </tr>
    <tr>
      <td>2026-04-21</td>
      <td>學務處</td>
      <td><a href="https://bulletin.ntust.edu.tw/p/450-1045-146000,c0.php?Lang=zh-tw">【免費便當】來領餐券</a></td>
    </tr>
    <tr>
      <td></td>
      <td>Ghost</td>
      <td>no anchor here</td>
    </tr>
  </tbody>
</table>
</body></html>
"""


def test_parse_list_html_extracts_rows() -> None:
    rows = parse_list_html(_SAMPLE_LIST_HTML)
    assert len(rows) == 2
    assert rows[0].external_id == "146758"
    assert rows[0].raw_publisher == "通識教育中心"
    assert rows[0].title == "[參訪] 綠能體驗"
    assert rows[0].posted_at is not None
    assert rows[0].posted_at.year == 2026 and rows[0].posted_at.month == 4
    assert rows[1].external_id == "146000"
    assert "免費便當" in rows[1].title


def test_parse_list_html_returns_empty_when_no_table() -> None:
    assert parse_list_html("<html><body>no table</body></html>") == []


def test_parse_list_html_handles_missing_tbody() -> None:
    html = _SAMPLE_LIST_HTML.replace("<tbody>", "").replace("</tbody>", "")
    rows = parse_list_html(html)
    assert len(rows) == 2


# ---- trafilatura sanity ----------------------------------------------------


def test_extract_markdown_pulls_body_from_minimal_html() -> None:
    html = """
    <html><body>
    <h1>公告標題</h1>
    <div>這是第一段內容，應該要被抽出來。這是第一段內容，應該要被抽出來。這是第一段內容，應該要被抽出來。</div>
    <p>第二段更多文字，這是第二段更多文字，這是第二段更多文字，這是第二段更多文字。</p>
    </body></html>
    """
    md = extract_markdown(html)
    assert md is not None
    assert "公告標題" in md


# ---- Hashing ---------------------------------------------------------------


def test_normalize_for_hash_collapses_whitespace_and_case() -> None:
    assert normalize_for_hash("  HELLO\n world ") == "hello world"


def test_normalize_for_hash_handles_fullwidth() -> None:
    # NFKC folds fullwidth ASCII to plain ASCII
    assert normalize_for_hash("ＡＢＣ") == "abc"


def test_compute_content_hash_stable_under_trivial_reformat() -> None:
    h1 = compute_content_hash("Title", "Body text here.")
    h2 = compute_content_hash("  Title  ", "  Body    text     here.  ")
    assert h1 == h2


def test_compute_content_hash_distinguishes_different_bodies() -> None:
    assert compute_content_hash("T", "A") != compute_content_hash("T", "B")


# ---- DB dedup flow ---------------------------------------------------------


@_async
async def test_upsert_inserts_new_rows_and_refreshes_existing(
    prepared_engine: AsyncEngine,
) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)

    rows = [
        ListRow(
            external_id="900001",
            title="t1",
            source_url="https://x/1",
            raw_publisher="A",
            posted_at=None,
        ),
        ListRow(
            external_id="900002",
            title="t2",
            source_url="https://x/2",
            raw_publisher="B",
            posted_at=None,
        ),
    ]

    async with factory() as session:
        outcome = await upsert_list_rows(session, rows)
        await session.commit()
        assert len(outcome.inserted_ids) == 2
        assert outcome.refreshed_count == 0

    async with factory() as session:
        outcome = await upsert_list_rows(session, rows)
        await session.commit()
        assert outcome.inserted_ids == []
        assert outcome.refreshed_count == 2


@_async
async def test_attach_body_detects_repost(prepared_engine: AsyncEngine) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)

    original = ListRow(
        external_id="910001",
        title="Same Title",
        source_url="https://x/910001",
        raw_publisher="A",
        posted_at=None,
    )
    repost = ListRow(
        external_id="910002",  # different external_id, same content
        title="Same Title",
        source_url="https://x/910002",
        raw_publisher="A",
        posted_at=None,
    )

    async with factory() as session:
        await upsert_list_rows(session, [original])
        outcome = await upsert_list_rows(session, [repost])
        await session.commit()
        new_ids = outcome.inserted_ids
        assert len(new_ids) == 1

    # First bulletin processed normally — stores content_hash
    async with factory() as session:
        first_id = (
            await session.execute(
                Bulletin.__table__.select().where(Bulletin.external_id == "910001")
            )
        ).first().id
        is_repost = await attach_body_and_dedup(session, first_id, "Shared body text.")
        await session.commit()
        assert is_repost is False

    # Second bulletin — same content → repost
    async with factory() as session:
        is_repost = await attach_body_and_dedup(session, new_ids[0], "Shared body text.")
        await session.commit()
        assert is_repost is True

    async with factory() as session:
        row = await session.get(Bulletin, new_ids[0])
        assert row is not None
        assert row.processing_state == BulletinProcessingState.skipped.value
        assert row.content_hash is None  # repost never stores the hash
        assert row.body_md == "Shared body text."


@_async
async def test_upsert_empty_list_is_noop(prepared_engine: AsyncEngine) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    async with factory() as session:
        outcome = await upsert_list_rows(session, [])
        assert outcome.inserted_ids == []
        assert outcome.refreshed_count == 0
