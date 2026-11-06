import gzip
import io
import json
from datetime import UTC, datetime

import httpx
import numpy as np
import pytest

from smooth_worker import archive
from smooth_worker.sources import gtg

NY, NX = 40, 60  # ~0.05 deg cells, so several 0.25 deg points fit with their whole window


@pytest.fixture(autouse=True)
def fake_grib(monkeypatch, tmp_path):
    """Hours decode from a made-up grid near JFK: EDR 0.01 x the hour, plus a 0.4 spike in one cell."""
    monkeypatch.setattr(gtg, "_grid", None)
    monkeypatch.setattr(archive, "_points", None)
    monkeypatch.setattr(archive, "ENABLED", True)
    decoded = []

    def download(self, fhr):
        path = self.cache_dir / f"{self.cycle:%Y%m%d%H}_f{fhr:03d}.grib2"
        path.write_bytes(b"grib")
        return path

    def decode(path):
        fhr = int(path.stem.split("_f")[1])
        decoded.append(fhr)
        lats, lons = np.meshgrid(np.linspace(39.0, 41.0, NY), np.linspace(-76.0, -73.0, NX), indexing="ij")
        levels = np.array([30000.0, 34000.0])
        edr = np.full((2, NY, NX), 0.01 * fhr, dtype=np.float16)
        j, i = np.unravel_index(np.argmin(np.hypot(lats - 40.0, lons + 74.5)), lats.shape)
        edr[1, j, i] = 0.4
        return levels, edr, lats, lons

    monkeypatch.setattr(gtg.GtgSource, "_download", download)
    monkeypatch.setattr(gtg, "decode", decode)
    return decoded


class FakeStore:
    def __init__(self, fail_after: int | None = None):
        self.saved: dict[str, bytes] = {}
        self.fail_after = fail_after

    def put(self, name, body):
        if self.fail_after is not None and len(self.saved) >= self.fail_after:
            raise RuntimeError("storage down")
        self.saved[name] = body


def hour(h: int) -> datetime:
    return datetime(2026, 10, 31, h, tzinfo=UTC)


def test_keeps_every_3h_analysis_and_6h_forecasts():
    kept = [(c, f) for c in range(24) for f in range(gtg.MAX_FHR + 1) if archive.wanted(hour(c), f)]
    assert len(kept) == 8 + 4 * 3
    assert archive.wanted(hour(3), 0) and not archive.wanted(hour(4), 0)
    assert archive.wanted(hour(6), 18) and not archive.wanted(hour(3), 6) and not archive.wanted(hour(6), 3)


def test_samples_an_hour_on_the_quarter_degree_grid(tmp_path):
    source = gtg.GtgSource(hour(12), tmp_path)
    source.cache(0)
    source.cache(6)
    data = archive.sample(source, 6)
    assert set(np.unique(data["lat4"] / 4)) <= {39.25, 39.5, 39.75, 40.0, 40.25, 40.5, 40.75}
    assert data["edr_max"].shape == data["edr_mean"].shape == (2, len(data["lat4"]))
    spike = (data["lat4"] == 160) & (data["lon4"] == -298)  # 40.0, -74.5
    assert data["edr_max"][1, spike] == round(0.4 / archive.EDR_UNIT)
    assert data["edr_max"][0, spike] == data["edr_mean"][0, spike] == 6  # 0.06 everywhere else
    assert data["edr_mean"][1, spike] == 6  # one cell of 81: the max shows it, the mean barely moves
    assert str(data["cycle"]) == hour(12).isoformat() and int(data["fhr"]) == 6


def test_saves_once_and_never_downloads(fake_grib, tmp_path):
    source = gtg.GtgSource(hour(12), tmp_path)
    assert archive.save_gtg(source, 0, tmp_path) is False  # not decoded: skipped, not fetched
    assert fake_grib == []
    source.cache(0)
    assert archive.save_gtg(source, 0, tmp_path) is True
    assert archive.save_gtg(gtg.GtgSource(hour(12), tmp_path), 0, tmp_path) is False
    assert archive.save_gtg(source, 1, tmp_path) is False  # not an hour the archive keeps
    assert (tmp_path / "archive/pending/gtg/2026/10/31/12z_f000.npz").exists()


def test_uploads_pending_files_and_retries_after_a_failure(tmp_path):
    for c in (0, 3, 6):
        source = gtg.GtgSource(hour(c), tmp_path)
        source.cache(0)
        archive.save_gtg(source, 0, tmp_path)
    store = FakeStore(fail_after=1)
    with pytest.raises(RuntimeError):
        archive.upload_pending(tmp_path, store)
    assert list(store.saved) == ["gtg/2026/10/31/00z_f000.npz"]
    store.fail_after = None
    assert archive.upload_pending(tmp_path, store) == 2
    assert not list((tmp_path / "archive/pending").rglob("*.npz"))
    with np.load(io.BytesIO(store.saved["gtg/2026/10/31/06z_f000.npz"])) as f:
        assert int(f["schema"]) == archive.SCHEMA and f["edr_max"].dtype == np.uint8


def test_prune_drops_the_oldest_pending_past_the_cap(tmp_path, monkeypatch):
    for c in (0, 3):
        source = gtg.GtgSource(hour(c), tmp_path)
        source.cache(0)
        archive.save_gtg(source, 0, tmp_path)
    size = (tmp_path / "archive/pending/gtg/2026/10/31/03z_f000.npz").stat().st_size
    monkeypatch.setattr(archive, "PENDING_MAX_BYTES", size)
    assert archive.prune(tmp_path) == 1
    assert [p.name for p in (tmp_path / "archive/pending").rglob("*.npz")] == ["03z_f000.npz"]


class FakeReports:
    """aviationweather.gov with one report per whole degree of a made-up patch, 400 at most a query."""

    def __init__(self, reports: list[dict]):
        self.reports, self.queries = reports, []

    def __call__(self, url, params):
        south, west, north, east = (float(v) for v in params["bbox"].split(","))
        self.queries.append((south, west, north, east))
        found = [r for r in self.reports if south <= r["lat"] <= north and west <= r["lon"] <= east]
        body = json.dumps(found[: archive.REPORTS_CAP]).encode() if found else b""
        return httpx.Response(200, content=body, request=httpx.Request("GET", url))


def _reports(n: int) -> list[dict]:
    return [
        {"obsTime": 1793900000 + k, "lat": 40.0 + (k % 30) / 10, "lon": -40.0 + k // 30 / 10,
         "rawOb": f"ARP TEST{k}", "tbInt1": "MOD" if k == 7 else "", "pirepType": "AIREP"}
        for k in range(n)
    ]


def test_splits_full_boxes_until_every_report_is_found(monkeypatch):
    fake = FakeReports(_reports(900))
    monkeypatch.setattr(archive, "get_with_retry", fake)
    monkeypatch.setattr(archive, "REPORTS_PAUSE", 0)
    rows = archive.report_rows(archive.fetch_reports(2))
    assert len(rows) == 900
    assert len(fake.queries) > 1
    assert {r["id"] for r in rows} == {r["id"] for r in archive.report_rows(fake.reports)}


def test_report_rows_drop_repeats_and_empty_fields():
    reports = _reports(3)
    rows = archive.report_rows(reports + reports[:1] + [{"obsTime": 1, "lat": None, "lon": 0}])
    assert len(rows) == 3
    assert "tbInt1" not in rows[0]


def test_saves_reports_once_an_hour_and_uploads_them(monkeypatch, tmp_path):
    monkeypatch.setattr(archive, "get_with_retry", FakeReports(_reports(5)))
    monkeypatch.setattr(archive, "REPORTS_PAUSE", 0)
    now = datetime(2026, 11, 5, 21, 40, tzinfo=UTC)
    assert archive.save_reports(now, tmp_path) == 5
    assert archive.save_reports(now.replace(minute=55), tmp_path) == 0
    store = FakeStore()
    assert archive.upload_pending(tmp_path, store) == 1
    body = json.loads(gzip.decompress(store.saved["reports/2026/11/05/21z.json.gz"]))
    assert len(body["reports"]) == 5
    assert body["reports"][0]["pirepType"] == "AIREP"


def test_bbox_edges_round_outwards():
    assert archive._bbox((39.375, -105.46875, 39.7265625, -104.765625)) == "39.37,-105.47,39.73,-104.76"
