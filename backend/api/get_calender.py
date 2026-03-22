import httpx
from bs4 import BeautifulSoup
import re
from urllib.parse import urljoin


def get_calendar_urls(url: str) -> dict[int, str]:
    resp = httpx.get(url, follow_redirects=True)
    soup = BeautifulSoup(resp.text, "html.parser")

    text_pattern = re.compile(r".*\d{3}.*ics.*", re.I)
    year_pattern = re.compile(r"(\d{3})")
    base_url = str(resp.url)

    result = {}
    for a in soup.select("ul li a"):
        text = a.get_text(" ", strip=True)
        href = a.get("href", "").strip()

        if text_pattern.match(text) and href.lower().endswith(".ics"):
            m = year_pattern.search(text)
            if m:
                result[int(m.group(1))] = urljoin(base_url, href)

    return result


if __name__ == "__main__":
    print(get_calendar_urls("https://r.xinshou.tw/ntust-calender"))
    # {
    #   114: 'https://www.academic.ntust.edu.tw/var/file/48/1048/img/788923882.ics',
    #   113: 'https://www.academic.ntust.edu.tw/var/file/48/1048/img/NTUST113.ics',
    #   112: 'https://www.academic.ntust.edu.tw/var/file/48/1048/img/NTUST112_.ics',
    #   111: 'https://www.academic.ntust.edu.tw/var/file/48/1048/img/NTUST111.ics',
    #   110: 'https://www.academic.ntust.edu.tw/var/file/48/1048/img/541567461.ics'
    # }
