"""One-shot backfill for NTUST bulletins.

Walks N list pages (default 1..20), upserts every row into the `bulletins`
table, drains every `pending` row through the LLM classifier, and finally
stamps `notified_at = now()` on everything so the dispatcher treats the
batch as already-delivered (no retroactive push spam).

Deliberately *not* reusing `scrape_job` because that path also runs
`_mark_stale_deleted`, which during backfill would flip anything not on
page 1 to `is_deleted=true`.

Usage on the VPS:

    cd /path/to/backend
    uv run python scripts/backfill_bulletins.py              # pages 1..20
    uv run python scripts/backfill_bulletins.py --pages 30   # pages 1..30
    uv run python scripts/backfill_bulletins.py \
        --start 5 --end 10 --concurrency 4 --no-suppress-push

Env vars (same as the server): `TIGERDUCK_DATABASE_URL`,
`TIGERDUCK_LLM_BASE_URL`, `TIGERDUCK_LLM_MODEL`, etc.
"""

from __future__ import annotations

import argparse
import asyncio
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import httpx
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

# Let the script run via `uv run python scripts/backfill_bulletins.py`
# from the backend/ directory. Adding the parent on sys.path means the
# `server` package imports below resolve regardless of CWD.
_BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(_BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(_BACKEND_DIR))

from server import _ssl_compat  # noqa: F401, E402  # relax OpenSSL 3 strict parsing for NTUST
from server.bulletins.dedup import attach_body_and_dedup, upsert_list_rows  # noqa: E402
from server.bulletins.detail import fetch_detail  # noqa: E402
from server.bulletins.jobs import claim_pending_bulletins  # noqa: E402
from server.bulletins.llm.base import LLMError, LLMProvider  # noqa: E402
from server.bulletins.models import Bulletin, BulletinProcessingState  # noqa: E402
from server.bulletins.scraper import fetch_list  # noqa: E402
from server.config import Settings  # noqa: E402
from server.db import build_engine, build_session_factory  # noqa: E402
from server.scheduler.runtime import build_llm_provider  # noqa: E402

# The NTUST Plone URL is `.../p/{prefix}-{subsite}-{category}-{page}.php`.
# The trailing `{page}` is what we swap. Match on the last `-N.php`.
_PAGE_RE = re.compile(r"-(\d+)\.php$")


def _url_for_page(template_url: str, page: int) -> str:
    if not _PAGE_RE.search(template_url):
        raise ValueError(
            f"bulletin_list_url {template_url!r} does not end with -N.php; "
            "cannot determine page suffix. Update TIGERDUCK_BULLETIN_LIST_URL "
            "or patch the pagination regex."
        )
    return _PAGE_RE.sub(f"-{page}.php", template_url)


async def _scrape_pages(
    settings: Settings,
    session_factory: async_sessionmaker[AsyncSession],
    pages: list[int],
    http_client: httpx.AsyncClient,
) -> tuple[int, int]:
    """Fetch and upsert the requested pages sequentially. Returns
    (new_inserted, refreshed) totals."""
    total_inserted = 0
    total_refreshed = 0
    now = datetime.now(timezone.utc)
    for page in pages:
        url = _url_for_page(settings.bulletin_list_url, page)
        print(f"[scrape] page {page} — GET {url}")
        try:
            rows = await fetch_list(url, http_client)
        except httpx.HTTPError as exc:
            print(f"  ! page {page} fetch failed: {exc}")
            continue
        if not rows:
            print(f"  (page {page} returned 0 rows — stopping early)")
            break

        async with session_factory() as session:
            outcome = await upsert_list_rows(session, rows, now=now)
            await session.commit()
        print(
            f"  parsed {len(rows)} rows — inserted {len(outcome.inserted_ids)}, "
            f"refreshed {outcome.refreshed_count}"
        )
        total_inserted += len(outcome.inserted_ids)
        total_refreshed += outcome.refreshed_count

    return total_inserted, total_refreshed


async def _process_one(
    session_factory: async_sessionmaker[AsyncSession],
    llm: LLMProvider,
    http_client: httpx.AsyncClient,
    bulletin: Bulletin,
    max_attempts: int,
) -> str:
    """Run one already-claimed bulletin through detail+dedup+LLM. Returns a
    short tag: processed / repost / failed / missing. processing_attempts
    was bumped at claim time."""
    bulletin_id = bulletin.id
    source_url = bulletin.source_url
    title = bulletin.title
    raw_publisher = bulletin.raw_publisher or ""

    try:
        detail = await fetch_detail(source_url, http_client)
    except httpx.HTTPError as exc:
        await _mark_failed(session_factory, bulletin_id, max_attempts, f"detail fetch: {exc}")
        return "failed"

    if detail is None:
        await _mark_failed(session_factory, bulletin_id, max_attempts, "trafilatura empty extract")
        return "failed"

    async with session_factory() as session:
        is_repost = await attach_body_and_dedup(session, bulletin_id, detail.body_md)
        await session.commit()
    if is_repost:
        return "repost"

    try:
        meta = await llm.classify(
            title=title,
            raw_publisher=raw_publisher,
            body_md=detail.body_md,
        )
    except LLMError as exc:
        await _mark_failed(session_factory, bulletin_id, max_attempts, f"llm: {exc}")
        return "failed"

    async with session_factory() as session:
        await session.execute(
            update(Bulletin)
            .where(Bulletin.id == bulletin_id)
            .values(
                canonical_org=meta.canonical_org.value,
                content_tags=[t.value for t in meta.content_tags],
                title_clean=meta.title or None,
                summary=meta.summary,
                body_clean=meta.body_clean,
                importance=meta.importance.value,
                processing_state=BulletinProcessingState.processed.value,
                processing_error=None,
                # processing_attempts already bumped at claim time
            )
        )
        await session.commit()
    return "processed"


async def _mark_failed(
    session_factory: async_sessionmaker[AsyncSession],
    bulletin_id: int,
    max_attempts: int,
    reason: str,
) -> None:
    async with session_factory() as session:
        bul = await session.get(Bulletin, bulletin_id)
        if bul is None:
            return
        stays_pending = bul.processing_attempts < max_attempts
        state = (
            BulletinProcessingState.pending.value
            if stays_pending
            else BulletinProcessingState.failed.value
        )
        await session.execute(
            update(Bulletin)
            .where(Bulletin.id == bulletin_id)
            .values(
                processing_state=state,
                processing_error=reason[:500],
                # processing_attempts already bumped at claim time
            )
        )
        await session.commit()
    print(f"  ! bulletin {bulletin_id} marked {state}: {reason[:80]}")


async def _drain_pending(
    session_factory: async_sessionmaker[AsyncSession],
    llm: LLMProvider,
    http_client: httpx.AsyncClient,
    max_attempts: int,
    concurrency: int,
    batch_size: int = 100,
) -> dict[str, int]:
    """Pick up every pending row (within attempt budget) and run it.

    Claims rows atomically with SELECT ... FOR UPDATE SKIP LOCKED so that
    if the scheduler's `process_job` happens to run concurrently, neither
    side duplicates LLM work. Claims in bounded batches to keep the
    transaction that holds the SKIP LOCKED lease short."""
    totals: dict[str, int] = {
        "processed": 0,
        "repost": 0,
        "failed": 0,
        "missing": 0,
    }
    semaphore = asyncio.Semaphore(concurrency)

    async def handle(bulletin: Bulletin) -> None:
        async with semaphore:
            result = await _process_one(
                session_factory, llm, http_client, bulletin, max_attempts
            )
            totals[result] = totals.get(result, 0) + 1
            done = sum(totals.values())
            print(f"  [{done}] bulletin {bulletin.id}: {result}")

    while True:
        claimed = await claim_pending_bulletins(
            session_factory, max_attempts=max_attempts, limit=batch_size
        )
        if not claimed:
            break

        print(f"[process] claimed {len(claimed)} rows — running up to "
              f"{concurrency} in parallel")
        await asyncio.gather(*(handle(bul) for bul in claimed))
    return totals


async def _preflight_llm(
    settings: Settings, http_client: httpx.AsyncClient
) -> None:
    """Fail fast with a clear message when the LLM endpoint is unreachable.

    Without this, every bulletin burns 3 retry attempts with full timeouts
    before the script notices the LLM is down — so a single misconfigured
    base_url silently turns a 10-minute backfill into a multi-hour stall.

    Two checks: TCP reachability via GET /models, and a one-token
    /chat/completions round-trip so we catch model-name mismatches too.
    """
    base = settings.llm_base_url.rstrip("/")
    try:
        r = await http_client.get(
            f"{base}/models",
            headers={"Authorization": f"Bearer {settings.llm_api_key}"},
            timeout=5.0,
        )
    except httpx.HTTPError as exc:
        raise SystemExit(
            f"! LLM preflight failed: GET {base}/models → {exc}\n"
            f"  Is llama-server actually reachable from THIS machine?\n"
            f"  (If it is on a different host, set TIGERDUCK_LLM_BASE_URL "
            f"to the correct host, or establish an ssh tunnel.)"
        ) from exc
    if r.status_code >= 400:
        raise SystemExit(
            f"! LLM preflight failed: GET {base}/models → HTTP {r.status_code}\n"
            f"  Body: {r.text[:200]}\n"
            f"  Likely the base_url is wrong or the server on that port is "
            f"not OpenAI-compatible."
        )

    try:
        r = await http_client.post(
            f"{base}/chat/completions",
            headers={"Authorization": f"Bearer {settings.llm_api_key}"},
            json={
                "model": settings.llm_model,
                "messages": [{"role": "user", "content": "ping"}],
                "max_tokens": 4,
                "temperature": 0,
            },
            timeout=15.0,
        )
    except httpx.HTTPError as exc:
        raise SystemExit(
            f"! LLM chat preflight failed: POST {base}/chat/completions → {exc}"
        ) from exc
    if r.status_code >= 400:
        raise SystemExit(
            f"! LLM chat preflight failed: HTTP {r.status_code}\n"
            f"  Body: {r.text[:300]}\n"
            f"  If body says 'model not found', adjust TIGERDUCK_LLM_MODEL "
            f"to match the model name llama-server actually loaded."
        )
    print(f"[preflight] LLM {base} reachable, model {settings.llm_model} ok")


async def _suppress_future_push(
    session_factory: async_sessionmaker[AsyncSession],
) -> int:
    """Stamp notified_at on every row that doesn't already have it.

    The dispatcher only considers rows where notified_at IS NULL, so this
    stops the next dispatcher tick from fan-ing out the entire backfill
    to every subscribed device.
    """
    ts = datetime.now(timezone.utc)
    async with session_factory() as session:
        result = await session.execute(
            update(Bulletin)
            .where(Bulletin.notified_at.is_(None))
            .values(notified_at=ts)
        )
        await session.commit()
    return result.rowcount or 0


async def main_async(args: argparse.Namespace) -> int:
    settings = Settings()
    if args.llm_timeout is not None:
        # Back-door override so one run can lean on a long timeout without
        # editing .env. The underlying provider reads this on construction.
        settings.llm_timeout_seconds = args.llm_timeout
    engine = build_engine(settings)
    session_factory = build_session_factory(engine)
    llm = build_llm_provider(settings)

    if args.start > args.end:
        print(f"! --start ({args.start}) must be <= --end ({args.end})")
        return 2
    pages = list(range(args.start, args.end + 1))

    print(f"[config] list_url={settings.bulletin_list_url}")
    print(f"[config] llm={settings.llm_base_url} model={settings.llm_model} "
          f"timeout={settings.llm_timeout_seconds}s")
    print(f"[config] pages={pages[0]}..{pages[-1]} "
          f"concurrency={args.concurrency} suppress_push={not args.no_suppress_push}")

    try:
        async with httpx.AsyncClient(
            follow_redirects=True,
            headers={"User-Agent": "TigerDuckBulletinBot/0.1 (backfill)"},
            # Match server/bulletins/jobs.default_http_client_factory — many
            # NTUST subdomains ship broken/incomplete chains that OpenSSL 3
            # rejects. See that function's docstring for the full reasoning.
            verify=False,
        ) as http_client:
            if not args.skip_preflight:
                await _preflight_llm(settings, http_client)

            inserted, refreshed = await _scrape_pages(
                settings, session_factory, pages, http_client
            )
            print(f"[scrape] done — {inserted} new, {refreshed} refreshed\n")

            totals = await _drain_pending(
                session_factory,
                llm,
                http_client,
                max_attempts=settings.bulletin_max_process_attempts,
                concurrency=args.concurrency,
            )
            print(f"[process] done — {totals}")

        if not args.no_suppress_push:
            suppressed = await _suppress_future_push(session_factory)
            print(f"[suppress] notified_at stamped on {suppressed} rows")
        else:
            print("[suppress] skipped — dispatcher WILL push these bulletins")
    finally:
        await llm.close()
        await engine.dispose()
    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--start", type=int, default=1, help="first page (inclusive)")
    parser.add_argument("--end", type=int, default=20, help="last page (inclusive)")
    parser.add_argument(
        "--pages",
        type=int,
        default=None,
        help="convenience: --pages N is equivalent to --start 1 --end N",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=3,
        help="parallel LLM/detail workers (default 3, llama.cpp tops out around 3-4)",
    )
    parser.add_argument(
        "--no-suppress-push",
        action="store_true",
        help="do NOT stamp notified_at — backfill will fan out pushes to every device",
    )
    parser.add_argument(
        "--skip-preflight",
        action="store_true",
        help="skip the LLM reachability check at startup (not recommended)",
    )
    parser.add_argument(
        "--llm-timeout",
        type=float,
        default=None,
        help="override per-request LLM timeout in seconds (default from "
             "TIGERDUCK_LLM_TIMEOUT_SECONDS or 120s). Bump to 240+ if "
             "running gemma-4-E4B at high concurrency on slower hardware.",
    )
    return parser


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()
    if args.pages is not None:
        args.start = 1
        args.end = args.pages
    try:
        return asyncio.run(main_async(args))
    except KeyboardInterrupt:
        print("\n! interrupted")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
