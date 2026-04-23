"""NTUST academic year calendar — scrape ICS URLs from public listing page."""

from __future__ import annotations

import re
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup

TEXT_PATTERN = re.compile(r".*\d{3}.*ics.*", re.I)
YEAR_PATTERN = re.compile(r"(\d{3})")


def get_calendar_urls(url: str) -> dict[int, str]:
    resp = httpx.get(url, follow_redirects=True)
    soup = BeautifulSoup(resp.text, "html.parser")
    base = str(resp.url)
    result: dict[int, str] = {}
    for a in soup.select("ul li a"):
        text = a.get_text(" ", strip=True)
        href = a.get("href", "").strip()
        if not href.lower().endswith(".ics") or not TEXT_PATTERN.match(text):
            continue
        if m := YEAR_PATTERN.search(text):
            result[int(m.group(1))] = urljoin(base, href)
    return result


if __name__ == "__main__":
    print(get_calendar_urls("https://r.xinshou.tw/ntust-calender"))
