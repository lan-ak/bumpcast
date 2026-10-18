from functools import cache

import httpx


@cache
def client() -> httpx.Client:
    # NOMADS sends a malformed content-length header over HTTP/2, so stay on HTTP/1.1.
    return httpx.Client(
        http2=False,
        timeout=httpx.Timeout(60, connect=15),
        follow_redirects=True,
        headers={"User-Agent": "smooth-turbulence-worker/0.1"},
    )
