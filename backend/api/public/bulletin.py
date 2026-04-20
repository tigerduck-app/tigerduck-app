"""NTUST 公告抓取 + 类别统计.

Usage:
    python -m api.public.bulletin           # default: category stats
    python -m api.public.bulletin stats
    python -m api.public.bulletin fetch     # async scrape into runtime/bulletin_pages/
"""

from __future__ import annotations

import asyncio
import sys
from collections import Counter

import httpx
from rich.progress import (BarColumn, MofNCompleteColumn, Progress, TextColumn,
                           TimeElapsedColumn, TimeRemainingColumn)

from api import RUNTIME_DIR

ORIGIN_URL = "https://bulletin.ntust.edu.tw/p/403-1045-1391-{page}.php"
PARSER_URL = "https://defuddle.md/api/parse"
OUTPUT_DIR = RUNTIME_DIR / "bulletin_pages"
TOTAL_PAGES = 335
CONCURRENCY = 1


async def _fetch_page(
    page: int,
    client: httpx.AsyncClient,
    sem: asyncio.Semaphore,
    progress: Progress,
    task_id: int,
) -> None:
    path = OUTPUT_DIR / f"{page}.md"
    if path.is_file():
        progress.advance(task_id)
        return
    async with sem:
        try:
            r = await client.get(ORIGIN_URL.format(page=page), timeout=10.0)
            r.raise_for_status()
            r = await client.post(PARSER_URL, timeout=10.0, json={"html": r.text})
            r.raise_for_status()
            await asyncio.to_thread(
                path.write_text, r.json()["content"], encoding="utf-8",
            )
            await asyncio.sleep(1)
        except Exception as e:
            print(f"[ERROR] page {page}: {e}", file=sys.stderr)
        finally:
            progress.advance(task_id)


async def fetch_all() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    sem = asyncio.Semaphore(CONCURRENCY)
    limits = httpx.Limits(
        max_connections=CONCURRENCY, max_keepalive_connections=CONCURRENCY,
    )
    async with httpx.AsyncClient(limits=limits, follow_redirects=True) as client:
        with Progress(
            TextColumn("[progress.description]{task.description}"),
            BarColumn(), MofNCompleteColumn(),
            TimeElapsedColumn(), TimeRemainingColumn(),
        ) as progress:
            task_id = progress.add_task("Fetching...", total=TOTAL_PAGES)
            await asyncio.gather(*[
                _fetch_page(i, client, sem, progress, task_id)
                for i in range(1, TOTAL_PAGES + 1)
            ])


def category_stats() -> None:
    topics: Counter[str] = Counter()
    for i in range(1, TOTAL_PAGES + 1):
        path = OUTPUT_DIR / f"{i}.md"
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8").splitlines()[2:]:
            parts = line.split("|")
            if len(parts) > 2:
                topics[parts[2].strip()] += 1
    for name, count in topics.most_common():
        print(f"{name}: {count}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "stats"
    if mode == "fetch":
        asyncio.run(fetch_all())
    elif mode == "stats":
        category_stats()
    else:
        print(f"unknown mode: {mode}. use 'fetch' or 'stats'.", file=sys.stderr)
        sys.exit(2)
