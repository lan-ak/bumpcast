from datetime import UTC, datetime, timedelta

import pytest

from smooth_worker import airports, forecast, is_due
from smooth_worker.route import build_profile, distance_nm

NOW = datetime(2026, 10, 18, 12, tzinfo=UTC)


class FakeSource:
    """Constant smooth air, with a bumpy band between two minutes after takeoff."""

    name = "gtg"
    cycle = NOW

    def __init__(self, bumpy=(-1, -1), edr=0.25):
        self.bumpy, self.bump_edr = bumpy, edr
        self.takeoff = None

    def covers(self, valid):
        return True

    def edr(self, lat, lon, altitude_ft, valid):
        self.takeoff = self.takeoff or valid
        minute = (valid - self.takeoff).total_seconds() / 60
        return self.bump_edr if self.bumpy[0] <= minute <= self.bumpy[1] else 0.03


def test_profile_shape():
    jfk, lax = airports.lookup("JFK"), airports.lookup("KLAX")
    points = build_profile(jfk, lax, NOW)
    assert 2100 < distance_nm(jfk, lax) < 2200
    assert 270 < points[-1].minute < 330
    assert points[0].phase == "climb" and points[-1].phase == "descent"
    assert max(p.altitude_ft for p in points) == 37000
    assert points[0].time == NOW + timedelta(minutes=15)  # taxi-out


def test_short_hop_caps_cruise():
    points = build_profile(airports.lookup("SFO"), airports.lookup("SJC"), NOW)
    assert max(p.altitude_ft for p in points) < 24000


def test_too_early_and_out_of_coverage():
    jfk, lax, lhr = airports.lookup("JFK"), airports.lookup("LAX"), airports.lookup("LHR")
    assert forecast.compute(jfk, lax, NOW + timedelta(hours=49), NOW, []).status == "too_early"
    assert forecast.compute(jfk, lhr, NOW + timedelta(hours=5), NOW, []).status == "out_of_coverage"


def test_smooth_flight():
    result = forecast.compute(airports.lookup("ORD"), airports.lookup("DEN"), NOW, NOW, [FakeSource()])
    assert result.status == "ready"
    assert result.grade == "smooth" and result.score == 100
    assert result.segments == []


def test_moderate_band_becomes_segment():
    source = FakeSource(bumpy=(40, 55), edr=0.25)
    result = forecast.compute(airports.lookup("ORD"), airports.lookup("DEN"), NOW, NOW, [source])
    assert result.grade == "bumpy"
    [segment] = result.segments
    assert (segment["start_min"], segment["end_min"], segment["severity"]) == (40, 55, "moderate")


@pytest.mark.parametrize(
    ("departure_in", "issued_ago", "status", "edited", "due"),
    [
        (timedelta(hours=60), None, None, False, True),  # never forecast
        (timedelta(hours=60), timedelta(hours=10), "too_early", False, False),
        (timedelta(hours=47), timedelta(hours=10), "too_early", False, True),  # entered window
        (timedelta(hours=30), timedelta(hours=2), "ready", False, False),  # GFS, fresh
        (timedelta(hours=30), timedelta(hours=7), "ready", False, True),  # GFS, stale
        (timedelta(hours=5), timedelta(minutes=70), "ready", False, True),  # GTG hourly
        (timedelta(hours=5), timedelta(minutes=10), "ready", True, True),  # flight edited
        (timedelta(hours=5), timedelta(hours=9), "out_of_coverage", False, False),
    ],
)
def test_is_due(departure_in, issued_ago, status, edited, due):
    issued = NOW - issued_ago if issued_ago else None
    flight = {
        "departure_at": (NOW + departure_in).isoformat(),
        "updated_at": ((issued or NOW) + timedelta(minutes=1 if edited else -60)).isoformat(),
        "forecasts": [{"issued_at": issued.isoformat(), "status": status}] if issued else [],
    }
    assert is_due(flight, NOW) is due


def test_gfs_outlook_never_severe(tmp_path):
    import numpy as np

    from smooth_worker.sources.gfs import GfsSource, MAX_OUTLOOK_EDR
    from smooth_worker.severity import SEVERE, classify

    source = GfsSource(NOW, tmp_path)
    source._lats = np.array([43.0, 42.75, 42.5, 42.25, 42.0])
    source._lons = np.array([286.5, 286.75, 287.0, 287.25, 287.5])
    mids = np.broadcast_to(np.array([30000.0, 34000.0])[:, None, None], (2, 5, 5)).copy()
    tis = np.zeros((2, 5, 5))
    tis[:, :, :] = 40.0  # far beyond Ellrod's severe guidance everywhere
    source._layers[2] = (mids, tis)
    edr = source.edr(42.5, -73.0, 32000, NOW + timedelta(hours=2))
    assert edr == MAX_OUTLOOK_EDR and classify(edr) != SEVERE
