#!/usr/bin/env python3
"""Render the App Store screenshots (6.9" iPhone, 1320 x 2868) from screenshots.html.

Serves the repo over localhost so the page can load the fonts and captures, then has headless
Chrome screenshot each frame. Frames 1 and 2 are the two halves of the opening panorama.

    python3 docs/release/creative/render_screenshots.py

Output: docs/release/creative/screenshots/en-US/NN-name.png
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
HTML = HERE / "screenshots.html"
OUT = HERE / "screenshots" / "en-US"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1320, 2868


def frames():
    """(section id, x offset, file name) for every screenshot, in order."""
    for m in re.finditer(r'<section class="frame[^"]*" id="([^"]+)" data-out="([^"]+)"', HTML.read_text()):
        for i, name in enumerate(m.group(2).split(",")):
            yield m.group(1), i * W, name


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
        for section, offset, name in frames():
            path = OUT / f"{name}.png"
            subprocess.run([
                CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                f"--user-data-dir={profile}", f"--window-size={W},{H}", "--virtual-time-budget=15000",
                f"--screenshot={path}", f"{page}#{section}:{offset}",
            ], check=True, capture_output=True)
            print(path.relative_to(ROOT))
    server.shutdown()


if __name__ == "__main__":
    main()
