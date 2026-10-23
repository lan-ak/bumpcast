from datetime import UTC, datetime

import numpy as np
import pytest

from smooth_worker.sources import gtg

CYCLE = datetime(2026, 10, 22, 12, tzinfo=UTC)
NY, NX = 6, 8


@pytest.fixture(autouse=True)
def fake_grib(monkeypatch, tmp_path):
    """Hours decode from a made-up 6x8 grid around JFK, with EDR rising with the hour."""
    monkeypatch.setattr(gtg, "_grid", None)
    decoded = []

    def download(self, fhr):
        path = self.cache_dir / f"{self.cycle:%Y%m%d%H}_f{fhr:03d}.grib2"
        path.write_bytes(b"grib")
        return path

    def decode(path):
        fhr = int(path.stem.split("_f")[1])
        decoded.append(fhr)
        lats, lons = np.meshgrid(np.linspace(40.0, 41.0, NY), np.linspace(-74.5, -73.0, NX), indexing="ij")
        levels = np.array([30000.0, 34000.0])
        edr = np.full((2, NY, NX), 0.01 * fhr, dtype=np.float16)
        return levels, edr, lats, lons

    monkeypatch.setattr(gtg.GtgSource, "_download", download)
    monkeypatch.setattr(gtg, "decode", decode)
    return decoded


def test_each_hour_decodes_once_and_the_grib_goes(fake_grib, tmp_path):
    source = gtg.GtgSource(CYCLE, tmp_path)
    assert source.cache(3) is True
    assert source.cache(3) is False
    assert fake_grib == [3]
    assert source.is_cached(3)
    assert not list((tmp_path / "gtg").glob("*.grib2"))


def test_a_new_source_reads_the_cache_without_decoding(fake_grib, tmp_path):
    first = gtg.GtgSource(CYCLE, tmp_path)
    value = first.edr(40.5, -73.8, 32000, datetime(2026, 10, 22, 15, tzinfo=UTC))
    second = gtg.GtgSource(CYCLE, tmp_path)
    again = second.edr(40.5, -73.8, 32000, datetime(2026, 10, 22, 15, tzinfo=UTC))
    assert value == again == pytest.approx(0.03, abs=1e-3)
    assert fake_grib == [3]  # decoded once, read back from disk after


def test_grid_comes_back_from_disk_in_a_new_process(fake_grib, tmp_path, monkeypatch):
    gtg.GtgSource(CYCLE, tmp_path).cache(5)
    monkeypatch.setattr(gtg, "_grid", None)  # as after a restart
    lats, lons, levels, edr = gtg.GtgSource(CYCLE, tmp_path).field(5)
    assert lats.shape == (NY * NX,) and edr.shape == (2, NY, NX)
    assert isinstance(edr, np.memmap)
    assert fake_grib == [5]


def test_prune_keeps_the_newest_cycles(fake_grib, tmp_path):
    for hour in (10, 11, 12):
        gtg.GtgSource(datetime(2026, 10, 22, hour, tzinfo=UTC), tmp_path).cache(0)
    assert gtg.prune(tmp_path, keep=2) == 2  # the 10Z hour's two files
    assert not gtg.GtgSource(datetime(2026, 10, 22, 10, tzinfo=UTC), tmp_path).is_cached(0)
    assert gtg.GtgSource(datetime(2026, 10, 22, 11, tzinfo=UTC), tmp_path).is_cached(0)
    assert (tmp_path / "gtg" / "grid_lats.npy").exists()


def test_prune_never_drops_the_only_complete_run_for_partial_ones(fake_grib, tmp_path):
    """10Z decoded in full; NOMADS throttled 11Z after six hours and 12Z came out meanwhile."""
    def hour(h):
        return datetime(2026, 10, 22, h, tzinfo=UTC)

    for fhr in range(gtg.MAX_FHR + 1):
        gtg.GtgSource(hour(10), tmp_path).cache(fhr)
    for fhr in range(6):
        gtg.GtgSource(hour(11), tmp_path).cache(fhr)
    gtg.GtgSource(hour(12), tmp_path).cache(0)
    assert gtg.prune(tmp_path, keep=2) == 12  # the abandoned 11Z hours
    assert gtg.ready_cycles(tmp_path) == [hour(10)]
    assert gtg.GtgSource(hour(12), tmp_path).is_cached(0)  # still being decoded
    # Once 12Z is complete, the next run decoding and 12Z stay, and 10Z goes.
    for fhr in range(1, gtg.MAX_FHR + 1):
        gtg.GtgSource(hour(12), tmp_path).cache(fhr)
    gtg.GtgSource(hour(13), tmp_path).cache(0)
    gtg.prune(tmp_path, keep=2)
    assert gtg.ready_cycles(tmp_path) == [hour(12)]
    assert gtg.GtgSource(hour(13), tmp_path).is_cached(0)


def test_forecasts_use_the_newest_decoded_run(fake_grib, tmp_path, monkeypatch):
    import smooth_worker

    monkeypatch.setattr(smooth_worker, "CACHE_DIR", tmp_path)
    for fhr in range(gtg.MAX_FHR + 1):
        gtg.GtgSource(datetime(2026, 10, 22, 11, tzinfo=UTC), tmp_path).cache(fhr)
    gtg.GtgSource(datetime(2026, 10, 22, 12, tzinfo=UTC), tmp_path).cache(0)  # 12Z still decoding
    assert gtg.ready_cycles(tmp_path) == [datetime(2026, 10, 22, 11, tzinfo=UTC)]
    now = datetime(2026, 10, 22, 14, tzinfo=UTC)

    def listed(cycle):
        monkeypatch.setattr(gtg, "latest_cycle", lambda now=None: cycle)
        return smooth_worker.gtg_cycle(now)

    assert listed(datetime(2026, 10, 22, 12, tzinfo=UTC)) == datetime(2026, 10, 22, 11, tzinfo=UTC)
    assert listed(datetime(2026, 10, 21, 23, tzinfo=UTC)) == datetime(2026, 10, 22, 11, tzinfo=UTC)  # a failed listing
    assert listed(None) == datetime(2026, 10, 22, 11, tzinfo=UTC)
    assert listed(datetime(2026, 10, 22, 13, tzinfo=UTC)) == datetime(2026, 10, 22, 13, tzinfo=UTC)  # decoding is behind
