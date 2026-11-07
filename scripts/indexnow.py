#!/usr/bin/env python3
"""Tell search engines that use IndexNow (Bing, which ChatGPT search and Copilot draw on, plus
Yandex, Seznam and Naver) about every page in site/sitemap.xml, so they crawl them soon.

Run it after scripts/publish_site.sh, once the pages are live:

    python3 scripts/indexnow.py

The key is the name of the <key>.txt file in site/ (published with the site, where IndexNow checks
it). It isn't a secret. Google doesn't use IndexNow: it reads the sitemap from robots.txt, and Search
Console (https://search.google.com/search-console) is where to submit it by hand.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
HOST = "bumpcast.app"
ENDPOINT = "https://api.indexnow.org/indexnow"


def main() -> None:
    keys = [p for p in SITE.glob("*.txt") if re.fullmatch(r"[0-9a-f]{32}", p.stem) and p.read_text().strip() == p.stem]
    if len(keys) != 1:
        sys.exit(f"indexnow: expected one <key>.txt in site/, found {len(keys)}")
    key = keys[0].stem
    urls = re.findall(r"<loc>([^<]+)</loc>", (SITE / "sitemap.xml").read_text())
    body = json.dumps({"host": HOST, "key": key, "keyLocation": f"https://{HOST}/{key}.txt", "urlList": urls}).encode()
    req = urllib.request.Request(ENDPOINT, data=body, headers={"Content-Type": "application/json; charset=utf-8"})
    with urllib.request.urlopen(req, timeout=60) as r:
        print(f"IndexNow: {r.status} for {len(urls)} URLs (200 or 202 means accepted)")


if __name__ == "__main__":
    main()
