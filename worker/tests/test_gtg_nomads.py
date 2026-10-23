"""NOMADS saying 'not now' (unpublished, or throttling us) is something to wait out, not an error."""

import logging
from datetime import UTC, datetime, timedelta

import httpx
import pytest

import smooth_worker
from smooth_worker.sources import gtg

CYCLE = datetime(2026, 10, 22, 14, tzinfo=UTC)
IDX = "\n".join(
    [
        "1:0:d=2026102214:EDPARM:9144 m above mean sea level:4 hour fcst:",
        "2:1000:d=2026102214:EDPARM:9753 m above mean sea level:4 hour fcst:",
        "3:2000:d=2026102214:CATEDR:9753 m above mean sea level:4 hour fcst:",
    ]
)


class FakeClient:
    """Answers each GET from `answer(url, headers)` -> (status, text), and records the URLs."""

    def __init__(self, answer):
        self.answer, self.urls = answer, []

    def get(self, url, headers=None, **kwargs):
        self.urls.append(url)
        status, text = self.answer(url, headers or {})
        return httpx.Response(status, text=text, request=httpx.Request("GET", url))


@pytest.fixture
def nomads(monkeypatch):
    def install(answer):
        fake = FakeClient(answer)
        monkeypatch.setattr(gtg, "client", lambda: fake)
        return fake

    return install


def _leftovers(tmp_path):
    return [p.name for p in (tmp_path / "gtg").iterdir() if p.suffix in (".grib2", ".part")]


@pytest.mark.parametrize("status", [302, 404, 429, 503])
def test_index_not_served_is_unavailable(nomads, tmp_path, status):
    nomads(lambda url, headers: (status, ""))
    with pytest.raises(gtg.Unavailable) as error:
        gtg.GtgSource(CYCLE, tmp_path)._download(4)
    assert error.value.status == status
    assert _leftovers(tmp_path) == []


@pytest.mark.parametrize("status", [302, 429, 502])
def test_throttled_mid_download_leaves_nothing_behind(nomads, tmp_path, status):
    calls = []

    def answer(url, headers):
        if url.endswith(".idx"):
            return 200, IDX
        calls.append(headers["Range"])
        return (206, "grib") if len(calls) == 1 else (status, "")

    nomads(answer)
    with pytest.raises(gtg.Unavailable) as error:
        gtg.GtgSource(CYCLE, tmp_path)._download(4)
    assert error.value.status == status and len(calls) == 2
    assert _leftovers(tmp_path) == []


def test_a_real_error_still_raises(nomads, tmp_path):
    nomads(lambda url, headers: (403, "forbidden"))
    with pytest.raises(httpx.HTTPStatusError):
        gtg.GtgSource(CYCLE, tmp_path)._download(4)


def test_a_served_hour_downloads(nomads, tmp_path):
    nomads(lambda url, headers: (200, IDX) if url.endswith(".idx") else (206, "grib"))
    path = gtg.GtgSource(CYCLE, tmp_path)._download(4)
    assert path.read_text() == "gribgrib"  # the two EDPARM levels, not CATEDR
    assert _leftovers(tmp_path) == [path.name]


def _listing(*hours: int) -> str:
    return "".join(f'<a href="dafs.t{h:02d}z.gtg.3km.conus.f018.grib2">' for h in hours)


def test_throttled_listing_finds_no_runs_and_stops(nomads):
    fake = nomads(lambda url, headers: (302, ""))
    assert gtg.latest_cycles(datetime(2026, 10, 22, 17, 20, tzinfo=UTC), 1) == []
    assert len(fake.urls) == 1  # never asks for yesterday's runs as well


def test_listing_falls_back_to_yesterday_only_early_in_the_day(nomads):
    yesterday = _listing(20, 21, 22)
    nomads(lambda url, headers: (404, "") if "dafs.20261022" in url else (200, yesterday))
    # Just after midnight today's directory doesn't exist yet: yesterday's late runs are the newest.
    assert gtg.latest_cycles(datetime(2026, 10, 22, 0, 30, tzinfo=UTC), 1) == [datetime(2026, 10, 21, 22, tzinfo=UTC)]
    # By the afternoon they're too old to forecast with.
    assert gtg.latest_cycles(datetime(2026, 10, 22, 17, 20, tzinfo=UTC), 1) == []


def test_listing_keeps_only_recent_runs(nomads):
    today, yesterday = _listing(0, 1), _listing(22, 23)
    nomads(lambda url, headers: (200, today if "dafs.20261022" in url else yesterday))
    now = datetime(2026, 10, 22, 4, tzinfo=UTC)
    assert gtg.latest_cycles(now, 3) == [
        datetime(2026, 10, 22, 1, tzinfo=UTC), datetime(2026, 10, 22, 0, tzinfo=UTC), datetime(2026, 10, 21, 23, tzinfo=UTC)
    ]
    # Later, with the listing stuck (e.g. a cached error page), only runs under 12 h old count.
    assert gtg.latest_cycles(now + timedelta(hours=8, minutes=30), 3) == [datetime(2026, 10, 22, 1, tzinfo=UTC)]


def test_prepare_gtg_stops_at_the_first_unavailable_hour(monkeypatch, tmp_path):
    decoded = []

    def cache(self, fhr):
        if fhr == 2:
            raise gtg.Unavailable(gtg._file(self.cycle, fhr) + ".idx", 429)
        decoded.append(fhr)
        return True

    monkeypatch.setattr(smooth_worker, "CACHE_DIR", tmp_path)
    monkeypatch.setattr(gtg, "latest_cycles", lambda now, count=2: [CYCLE])
    monkeypatch.setattr(gtg.GtgSource, "cache", cache)
    with pytest.raises(gtg.Unavailable):
        smooth_worker.prepare_gtg(CYCLE + timedelta(hours=3), pace=0)
    assert decoded == [0, 1]


@pytest.mark.parametrize(
    ("status", "wait"),
    [(302, smooth_worker.GTG_THROTTLED_SECONDS), (429, smooth_worker.GTG_THROTTLED_SECONDS), (404, smooth_worker.GTG_CHECK_SECONDS)],
)
def test_gtg_step_backs_off_when_throttled(monkeypatch, caplog, status, wait):
    def unavailable(now):
        raise gtg.Unavailable("https://nomads.example/dafs.t14z.gtg.3km.conus.f004.grib2.idx", status)

    monkeypatch.setattr(smooth_worker, "prepare_gtg", unavailable)
    with caplog.at_level(logging.INFO):
        assert smooth_worker.gtg_step() == wait
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR or r.exc_info]


def test_gtg_step_after_a_pass(monkeypatch):
    monkeypatch.setattr(smooth_worker, "prepare_gtg", lambda now: 3)
    assert smooth_worker.gtg_step() == smooth_worker.GTG_CHECK_SECONDS

    def broken(now):
        raise ValueError("bad GRIB")

    monkeypatch.setattr(smooth_worker, "prepare_gtg", broken)
    assert smooth_worker.gtg_step() == smooth_worker.GTG_CHECK_SECONDS
