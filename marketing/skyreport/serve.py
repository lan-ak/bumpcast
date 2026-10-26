#!/usr/bin/env python3
"""Serve the website live from the latest Sky Report: the Cloud Run service behind the domain.

The same pages as build_site.py, rendered from the latest report in Supabase and kept for
REFRESH (5 minutes), so they're never more than a few minutes behind the worker and there's no
build to schedule. If Supabase can't be reached, the last report keeps being served. A report
older than rpt.MAX_AGE is still served, with the "hasn't been updated" note shown.

    SUPABASE_URL=… SUPABASE_ANON_KEY=… BASE_URL=https://<domain> python3 marketing/skyreport/serve.py
    REPORT_FILE=marketing/skyreport/fixtures/sample-report.json ALLOW_SAMPLE=1 BASE_URL=http://localhost:8080 \\
      python3 marketing/skyreport/serve.py                                    # local preview

Deploy: marketing/skyreport/deploy_gcp.sh
"""

import logging
import os
import threading
import time
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import build_site
import report as rpt

log = logging.getLogger("sky-site")

REFRESH = 300  # seconds
PAGE_CACHE = "public, max-age=300"
ASSET_CACHE = "public, max-age=86400"
TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".ttf": "font/ttf",
         ".xml": "application/xml; charset=utf-8", ".txt": "text/plain; charset=utf-8"}
# The only files served from disk: nothing in a request path is ever joined onto a directory.
STATIC = {f"/{p.name}": p for p in rpt.ROOT.joinpath("site").iterdir() if p.suffix in (".html", ".css")}
STATIC["/"] = STATIC.pop("/index.html")
STATIC |= {f"/fonts/{name}": rpt.FONTS / name for name in build_site.FONT_FILES}

NOT_FOUND = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Not found | BumpCast</title>
<link rel="stylesheet" href="/sky.css"></head><body><main><p class="eyebrow"><a href="/">BumpCast</a></p>
<h1>We couldn't find that page</h1><p><a href="/routes/">See every route in the Sky Report</a></p></main></body></html>"""


class Site:
    """The rendered pages for one report, swapped whole when a newer report comes in."""

    def __init__(self, base: str, report_file: str | None, allow_sample: bool):
        self.base, self.report_file, self.allow_sample = base, report_file, allow_sample
        self.pages: dict[str, bytes] = {}
        self.generated_at: str | None = None
        self.checked = float("-inf")  # monotonic() can be under REFRESH on a fresh machine
        self.lock = threading.Lock()
        self.assets = {path: file.read_bytes() for path, file in STATIC.items()}
        self.assets["/sky.css"] = build_site.CSS.lstrip().encode()

    def refresh(self) -> None:
        """Reload when REFRESH has passed. One request reloads; the rest keep the current pages."""
        if time.monotonic() - self.checked < REFRESH or not self.lock.acquire(blocking=False):
            return
        try:
            self.checked = time.monotonic()
            report = rpt.load(self.report_file)
            if report.get("sample") and not self.allow_sample:
                raise RuntimeError("the sample report is only for previews (ALLOW_SAMPLE=1)")
            if report["generated_at"] != self.generated_at or not self.pages:
                self.pages = self.render(report, rpt.accuracy(self.report_file))
                self.generated_at = report["generated_at"]
                log.info("report %s: %d pages", self.generated_at, len(self.pages))
        except (Exception, SystemExit):  # rpt.load exits when there is no report
            log.exception("report refresh failed; serving the last one (%s)", self.generated_at)
        finally:
            self.lock.release()

    def render(self, report: dict, stats: dict | None) -> dict[str, bytes]:
        stale = datetime.now(UTC) - rpt.parse_time(report["generated_at"]) > rpt.MAX_AGE
        if stale:
            log.warning("report from %s is older than %s: pages say so", report["generated_at"], rpt.MAX_AGE)

        def html(text: str) -> bytes:
            return (text.replace('<div class="stale">', '<div class="stale on">') if stale else text).encode()

        pages = {"/routes/": html(build_site.index_page(report, self.base))}
        for route in report["routes"]:
            others = [r for r in report["routes"] if r is not route]
            pages[f"/routes/{route['slug']}/"] = html(build_site.route_page(route, report, others, stats, self.base))
        pages["/sitemap.xml"] = build_site.sitemap(report, self.base).encode()
        pages["/robots.txt"] = build_site.robots(self.base).encode()
        return pages


class Handler(BaseHTTPRequestHandler):
    site: Site
    server_version = "BumpCast"
    sys_version = ""

    def do_HEAD(self):
        self.respond(head_only=True)

    def do_GET(self):
        self.respond()

    def respond(self, head_only: bool = False):
        path, _, query = self.path.split("#", 1)[0].partition("?")
        if path == "/healthz":
            return self.send(200, b"ok", ".txt", "no-store", head_only)
        if path in self.site.assets:
            ext = ".html" if path == "/" else os.path.splitext(path)[1]
            return self.send(200, self.site.assets[path], ext, ASSET_CACHE if "/fonts/" in path else PAGE_CACHE, head_only)
        self.site.refresh()
        if path in self.site.pages:
            ext = os.path.splitext(path)[1] or ".html"
            return self.send(200, self.site.pages[path], ext, PAGE_CACHE, head_only)
        if path == "/routes" or (path.startswith("/routes/") and f"{path}/" in self.site.pages):
            return self.redirect(f"{path}/" + (f"?{query}" if query else ""))  # keeps utm_ tags
        if path.startswith("/routes") and not self.site.pages:
            return self.send(503, b"The Sky Report is being updated. Try again in a few minutes.", ".txt", "no-store", head_only)
        self.send(404, NOT_FOUND.encode(), ".html", "public, max-age=60", head_only)

    def redirect(self, location: str):
        self.send_response(301)
        self.send_header("Location", location)
        self.send_header("Cache-Control", ASSET_CACHE)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send(self, code: int, body: bytes, ext: str, cache: str, head_only: bool):
        self.send_response(code)
        self.send_header("Content-Type", TYPES.get(ext, "application/octet-stream"))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "strict-origin-when-cross-origin")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # Cloud Run logs every request already


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    base = os.environ["BASE_URL"].rstrip("/")
    site = Site(base, os.environ.get("REPORT_FILE"), os.environ.get("ALLOW_SAMPLE") == "1")
    site.refresh()
    Handler.site = site
    port = int(os.environ.get("PORT", "8080"))
    log.info("serving %s on :%d", base, port)
    ThreadingHTTPServer(("", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
