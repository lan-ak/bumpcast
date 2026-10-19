import time
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


def get_with_retry(url: str, attempts: int = 3, **kwargs) -> httpx.Response:
    """GET that retries dropped connections and server errors (NOMADS does both under load)."""
    for attempt in range(attempts):
        try:
            r = client().get(url, **kwargs)
            if r.status_code < 500 or attempt == attempts - 1:
                return r
        except httpx.TransportError:
            if attempt == attempts - 1:
                raise
        time.sleep(2 * (attempt + 1))
    raise AssertionError("unreachable")
