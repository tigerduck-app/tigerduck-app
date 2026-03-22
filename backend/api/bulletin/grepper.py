import os
from asyncio import sleep
from collections import Counter

import httpx
import asyncio
from rich.progress import (
    Progress,
    TextColumn,
    BarColumn,
    MofNCompleteColumn,
    TimeElapsedColumn,
    TimeRemainingColumn,
)

ORIGIN_URL = "https://bulletin.ntust.edu.tw/p/403-1045-1391-{PAGE}.php"
TARGET_URL = "https://defuddle.md/bulletin.ntust.edu.tw/p/403-1045-1391-{PAGE}.php"
TARGET_URL2 = "https://defuddle.md/api/parse"
OUTPUT_DIR = "bulletin/pages"
CONCURRENCY = 1


def write_file(path: str, content: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


async def fetch_page(
    page: int,
    client: httpx.AsyncClient,
    sem: asyncio.Semaphore,
    progress: Progress,
    task_id: int,
) -> None:
    file_path = f"{OUTPUT_DIR}/{page}.md"

    if os.path.isfile(file_path):
        progress.advance(task_id)
        return

    async with sem:
        try:
            resp = await client.get(ORIGIN_URL.format(PAGE=page), timeout=10.0)
            resp.raise_for_status()

            resp = await client.post(
                TARGET_URL2,
                timeout=10.0,
                json={"html": resp.text},
            )
            resp.raise_for_status()

            content = resp.json()["content"]
            await asyncio.to_thread(write_file, file_path, content)
            await sleep(1)

        except Exception as e:
            print(f"[ERROR] page {page}: {e}")

        finally:
            progress.advance(task_id)


async def main() -> None:
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    sem = asyncio.Semaphore(CONCURRENCY)
    limits = httpx.Limits(
        max_connections=CONCURRENCY,
        max_keepalive_connections=CONCURRENCY,
    )

    async with httpx.AsyncClient(limits=limits, follow_redirects=True) as client:
        with Progress(
            TextColumn("[progress.description]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            TimeElapsedColumn(),
            TimeRemainingColumn(),
        ) as progress:
            task_id = progress.add_task("Fetching...", total=335)

            tasks = [
                fetch_page(i, client, sem, progress, task_id) for i in range(1, 336)
            ]
            await asyncio.gather(*tasks)


if __name__ == "__main__":
    # asyncio.run(main())
    topics = Counter()
    for i in range(1, 336):
        with open(f"bulletin/pages/{i}.md", "r") as f:
            for line in f.readlines()[2:]:
                topics[line.split("|")[2].strip()] += 1

    for i, j in topics.most_common(len(topics)):
        print(f"{i}: {j}")
