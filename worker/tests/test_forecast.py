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

    from smooth_worker.severity import SEVERE, classify
    from smooth_worker.sources.gfs import MAX_OUTLOOK_EDR, GfsSource, tile_of

    source = GfsSource(NOW, tmp_path)
    lats = np.array([43.0, 42.75, 42.5, 42.25, 42.0])
    lons = np.array([286.5, 286.75, 287.0, 287.25, 287.5])
    mids = np.broadcast_to(np.array([30000.0, 34000.0])[:, None, None], (2, 5, 5)).copy()
    edr = np.full((2, 5, 5), 0.6)  # far beyond severe everywhere
    source._tiles[(2, tile_of(42.5, -73.0))] = (lats, lons, mids, edr)
    value = source.edr(42.5, -73.0, 32000, NOW + timedelta(hours=2))
    assert value == MAX_OUTLOOK_EDR and classify(value) != SEVERE


def _gfs_fields(shear_ms: float, ny: int = 9, nx: int = 9):
    """Uniform westerlies at every level, increasing by `shear_ms` per level, plus a shear zone across the grid."""
    import numpy as np

    from smooth_worker.sources.gfs import LEVELS_MB

    fields = {}
    heights = {850: 1500, 700: 3000, 600: 4200, 500: 5600, 400: 7200, 350: 8100, 300: 9200, 250: 10400, 200: 11800, 150: 13600}
    temps = {850: 285, 700: 275, 600: 267, 500: 258, 400: 245, 350: 237, 300: 229, 250: 222, 200: 218, 150: 216}
    across = np.linspace(-1, 1, ny)[:, None] * np.ones((1, nx))
    for k, mb in enumerate(LEVELS_MB):
        fields[("u", mb)] = 10 + shear_ms * k + shear_ms * 2 * across
        fields[("v", mb)] = np.zeros((ny, nx))
        fields[("gh", mb)] = np.full((ny, nx), float(heights[mb]))
        fields[("t", mb)] = np.full((ny, nx), float(temps[mb]))
    return fields, np.linspace(42, 40, ny), np.linspace(280, 282, nx)


def test_gfs_blend_rises_with_shear():
    from smooth_worker.severity import LIGHT_EDR
    from smooth_worker.sources.gfs import blend_edr

    calm_mids, calm = blend_edr(*_gfs_fields(0.0))
    _, sheared = blend_edr(*_gfs_fields(12.0))
    assert calm.max() < LIGHT_EDR
    assert sheared.mean() > calm.mean() and sheared.max() >= LIGHT_EDR
    assert calm_mids.shape == calm.shape and (calm_mids[1:] > calm_mids[:-1]).all()


def test_gfs_mountain_wave_term():
    import numpy as np

    from smooth_worker.sources.gfs import blend_edr

    fields, lats, lons = _gfs_fields(0.0)
    flat_mids, flat = blend_edr(fields, lats, lons)
    fields[("u", 700)] = np.full(fields[("u", 700)].shape, 25.0)
    fields[("orog", 0)] = np.linspace(0, 3000, len(lons))[None, :] * np.ones((len(lats), 1))  # steep slope, wind across it
    _, wavy = blend_edr(fields, lats, lons)
    assert wavy.max() > flat.max()


def test_tiles_cover_the_globe():
    from smooth_worker.sources.gfs import tile_box, tile_of

    for lat, lon in [(51.5, -0.5), (-33.9, 151.2), (64.8, -147.9), (0.0, 179.9), (-89.9, -179.9), (89.9, 0.0)]:
        box = tile_box(tile_of(lat, lon))
        assert box["bottomlat"] <= lat <= box["toplat"]
        assert box["leftlon"] <= lon % 360 <= box["rightlon"]


class RegionSource:
    """Smooth air, but only inside a longitude band (stands in for GTG's US grid)."""

    def __init__(self, name, west=-180.0, east=180.0, edr=0.03, horizon_h=None):
        self.name, self.cycle, self.west, self.east, self.value = name, NOW, west, east, edr
        if horizon_h is not None:
            self.horizon_h = horizon_h

    def covers(self, valid):
        return True

    def covers_point(self, lat, lon):
        return self.west <= lon <= self.east

    def in_domain(self, lat, lon):
        return self.covers_point(lat, lon)

    def edr(self, lat, lon, altitude_ft, valid):
        return self.value


def test_global_route_mixes_sources_by_place():
    jfk, lhr = airports.lookup("JFK"), airports.lookup("LHR")
    gtg = RegionSource("gtg", west=-128, east=-64)
    gfs = RegionSource("gfs")
    result = forecast.compute(jfk, lhr, NOW + timedelta(hours=1), NOW, [gtg, gfs], global_coverage=True)
    assert result.status == "ready" and result.source == "mixed"
    assert [s["source"] for s in result.sources] == ["gtg", "gfs"]
    assert result.sources[0]["start_min"] == 0 and result.sources[-1]["end_min"] == result.duration_min
    assert result.noaa_possible is False
    assert {"sources", "warnings", "noaa_possible"} <= result.to_row().keys()


def test_us_route_stays_noaa_possible_and_old_mode_unchanged():
    ord_, den, lhr = airports.lookup("ORD"), airports.lookup("DEN"), airports.lookup("LHR")
    gtg = RegionSource("gtg", west=-128, east=-64)
    result = forecast.compute(ord_, den, NOW, NOW, [gtg, RegionSource("gfs")], global_coverage=True)
    assert result.source == "gtg" and result.noaa_possible is True
    old = forecast.compute(ord_, lhr, NOW, NOW, [gtg], global_coverage=False)
    assert old.status == "out_of_coverage" and "sources" not in old.to_row()


def test_global_route_outside_every_source():
    result = forecast.compute(
        airports.lookup("LHR"), airports.lookup("CDG"), NOW, NOW, [RegionSource("gtg", west=-128, east=-64)],
        global_coverage=True,
    )
    assert result.status == "out_of_coverage"


def test_handoff_eases_towards_outlook():
    from smooth_worker.forecast import HANDOFF_MIN_WEIGHT, _handoff_weight

    gtg = RegionSource("gtg", horizon_h=18)
    assert _handoff_weight(gtg, NOW + timedelta(hours=10)) == 1.0
    assert HANDOFF_MIN_WEIGHT < _handoff_weight(gtg, NOW + timedelta(hours=16.5)) < 1.0
    assert _handoff_weight(gtg, NOW + timedelta(hours=18)) == HANDOFF_MIN_WEIGHT
    assert _handoff_weight(RegionSource("gfs"), NOW + timedelta(hours=40)) == 1.0


def test_gtg_ensemble_blends_but_keeps_severe():
    from smooth_worker.sources.gtg import GtgEnsemble

    calm_new, rough_old = RegionSource("gtg", edr=0.10), RegionSource("gtg", edr=0.30)
    blended = GtgEnsemble([calm_new, rough_old]).edr(40, -100, 35000, NOW)
    assert 0.10 < blended < 0.30
    severe_new = RegionSource("gtg", edr=0.40)
    assert GtgEnsemble([severe_new, RegionSource("gtg", edr=0.05)]).edr(40, -100, 35000, NOW) == 0.40
