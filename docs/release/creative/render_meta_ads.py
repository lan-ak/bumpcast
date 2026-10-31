#!/usr/bin/env python3
"""Render the Meta ad frames (feed 1080 x 1350, story 1080 x 1920) from meta-ads.html.

Serves the repo over localhost so the page can load the fonts and captures, then has headless
Chrome screenshot each frame.

    python3 docs/release/creative/render_meta_ads.py

Output: docs/release/creative/meta-ads/NN-name-{feed,story}.png
"""

import functools
import http.server
import re
import subprocess
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
HTML = HERE / "meta-ads.html"
OUT = HERE / "meta-ads"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SIZES = {"feed": (1080, 1350), "story": (1080, 1920)}


def frames():
    """(section id, size, file name) for every frame, in order."""
    for m in re.finditer(r'<section class="frame (feed|story)[^"]*" id="([^"]+)" data-out="([^"]+)"', HTML.read_text()):
        yield m.group(2), SIZES[m.group(1)], m.group(3)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    handler = functools.partial(QuietHandler, directory=str(ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    page = f"http://127.0.0.1:{server.server_port}/{HTML.relative_to(ROOT)}"

    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as profile:
        for section, (w, h), name in frames():
            path = OUT / f"{name}.png"
            subprocess.run([
                CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                f"--user-data-dir={profile}", f"--window-size={w},{h}", "--virtual-time-budget=15000",
                f"--screenshot={path}", f"{page}#{section}",
            ], check=True, capture_output=True)
            print(path.relative_to(ROOT))
    server.shutdown()


if __name__ == "__main__":
    main()
