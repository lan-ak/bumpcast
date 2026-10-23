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
    # Westbound: FL360 (even levels), then one step climb to FL380, as UAL548 EWR-SFO flew.
    assert max(p.altitude_ft for p in points) == 38000
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
    ("departure_in", "issued_ago", "status", "edited", "due", "source"),
    [
        (timedelta(hours=60), None, None, False, True, None),  # never forecast
        (timedelta(hours=60), timedelta(hours=10), "too_early", False, False, None),
        (timedelta(hours=47), timedelta(hours=10), "too_early", False, True, None),  # entered window
        (timedelta(hours=30), timedelta(hours=2), "ready", False, False, "gfs"),  # GFS, fresh
        (timedelta(hours=30), timedelta(hours=7), "ready", False, True, "gfs"),  # GFS, stale
        (timedelta(hours=5), timedelta(minutes=70), "ready", False, True, "gtg"),  # GTG hourly
        (timedelta(hours=5), timedelta(minutes=10), "ready", True, True, "gtg"),  # flight edited
        (timedelta(hours=5), timedelta(hours=9), "out_of_coverage", False, False, None),
        # GFS only where GTG reaches: GTG was missing, so try again within minutes.
        (timedelta(hours=5), timedelta(minutes=15), "ready", False, True, "gfs"),
        (timedelta(hours=5), timedelta(minutes=5), "ready", False, False, "gfs"),
        (timedelta(hours=5), timedelta(minutes=15), "ready", False, False, "gtg"),
        (timedelta(hours=17), timedelta(minutes=15), "ready", False, False, "gfs"),  # beyond GTG's reach yet
    ],
)
def test_is_due(departure_in, issued_ago, status, edited, due, source):
    issued = NOW - issued_ago if issued_ago else None
    flight = {
        "departure_at": (NOW + departure_in).isoformat(),
        "updated_at": ((issued or NOW) + timedelta(minutes=1 if edited else -60)).isoformat(),
        "forecasts": [{"issued_at": issued.isoformat(), "status": status, "source": source}] if issued else [],
    }
    assert is_due(flight, NOW) is due


def test_gfs_outlook_stays_light(tmp_path):
    import numpy as np

    from smooth_worker.severity import LIGHT, MODERATE_EDR, classify
    from smooth_worker.sources.gfs import MAX_OUTLOOK_EDR, GfsSource, tile_of

    source = GfsSource(NOW, tmp_path)
    lats = np.array([43.0, 42.75, 42.5, 42.25, 42.0])
    lons = np.array([286.5, 286.75, 287.0, 287.25, 287.5])
    mids = np.broadcast_to(np.array([30000.0, 34000.0])[:, None, None], (2, 5, 5)).copy()
    edr = np.full((2, 5, 5), 0.6)  # far beyond severe everywhere
    source._tiles[(2, tile_of(42.5, -73.0))] = (lats, lons, mids, edr)
    value = source.edr(42.5, -73.0, 32000, NOW + timedelta(hours=2))
    assert value == MAX_OUTLOOK_EDR == 0.20
    assert value < MODERATE_EDR and classify(value) == LIGHT


def test_ewr_yyz_outlook_is_a_few_bumps_not_bumpy():
    """The real GFS-only forecast of 2026-10-22 17:20Z: moderate at the old 0.30 cap, while every
    GTG run said light. Capped at light it grades as GTG did."""
    import json
    from pathlib import Path

    from smooth_worker.forecast import _grade, _segments
    from smooth_worker.severity import MODERATE
    from smooth_worker.sources.gfs import MAX_OUTLOOK_EDR

    sample = json.loads((Path(__file__).parent / "fixtures" / "ewr_yyz_gfs_2026102212.json").read_text())
    # The stored minutes (the 52-minute plan of the time); grading reads only the EDR.
    assert len(sample["edr"]) == 53

    def samples(cap: float) -> list[dict]:
        return [
            {"min": minute, "edr": min(edr, cap), "altitude_ft": 31000, "phase": "cruise"}
            for minute, edr in enumerate(sample["edr"])
        ]

    assert _grade(samples(0.30))[0] == "bumpy"  # as stored
    capped = samples(MAX_OUTLOOK_EDR)
    assert _grade(capped)[0] == "some_bumps"
    assert all(seg["severity"] != MODERATE for seg in _segments(capped))


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


def test_a_forecast_kept_through_a_delay_is_retried_within_minutes():
    """A GTG forecast copied to a delayed departure (GTG was unavailable) was never computed for
    that time: it's retried like an outlook, not left for the hourly refresh."""
    departure = NOW + timedelta(hours=5)
    copy = {
        "issued_at": (NOW - timedelta(minutes=15)).isoformat(),
        "status": "ready",
        "source": "gtg",
        "departure_at": departure.isoformat(),
        "retimed": True,
    }
    flight = {
        "departure_at": (departure - timedelta(minutes=40)).isoformat(),
        "updated_at": (NOW - timedelta(days=1)).isoformat(),
        "forecasts": [copy],
    }
    assert is_due(flight, NOW, departure)
    assert not is_due({**flight, "forecasts": [{**copy, "issued_at": (NOW - timedelta(minutes=5)).isoformat()}]}, NOW, departure)
    # One really computed for that departure waits for the hourly refresh.
    assert not is_due({**flight, "forecasts": [{**copy, "retimed": False}]}, NOW, departure)


class RunSource:
    """A model run: covers from its start (GTG from half an hour before, its hours are rounded)."""

    def __init__(self, name, cycle, edr=0.05, early=timedelta(0), hours=120):
        self.name, self.cycle, self.value, self.early, self.hours = name, cycle, edr, early, hours
        self.read = []

    def covers(self, valid):
        return self.cycle - self.early <= valid <= self.cycle + timedelta(hours=self.hours)

    def covers_point(self, lat, lon):
        return True

    def edr(self, lat, lon, altitude_ft, valid):
        self.read.append(valid)
        return self.value


@pytest.mark.parametrize("wide", [False, True])
def test_a_flight_saved_in_the_air_before_the_oldest_run_is_forecast(wide):
    """17:00Z: GTG 15Z and GFS 12Z. JFK-LAX left at 11:30Z, before either run began."""
    now = datetime(2026, 10, 23, 17, tzinfo=UTC)
    gtg = RunSource("gtg", datetime(2026, 10, 23, 15, tzinfo=UTC), early=timedelta(minutes=30), hours=18)
    gfs = RunSource("gfs", datetime(2026, 10, 23, 12, tzinfo=UTC))
    departure = datetime(2026, 10, 23, 11, 30, tzinfo=UTC)
    result = forecast.compute(airports.lookup("JFK"), airports.lookup("LAX"), departure, now, [gtg, gfs], global_coverage=wide)
    assert result.status == "ready" and result.source == "mixed"
    # The minutes flown before 12Z read GFS's start; everything after reads its own time.
    assert min(gfs.read) == gfs.cycle and gfs.read.count(gfs.cycle) == 16
    assert min(gtg.read) == datetime(2026, 10, 23, 14, 30, tzinfo=UTC)


@pytest.mark.parametrize("wide", [False, True])
def test_in_the_air_the_minutes_still_ahead_say_how_confirmed_it_is(wide):
    """16:00Z, 40 minutes from landing: GTG 15Z covers all of them. The minutes flown before
    14:30 read GFS, but the rest of the flight is confirmed, not 'partly'."""
    now = datetime(2026, 10, 23, 16, tzinfo=UTC)
    gtg = RunSource("gtg", datetime(2026, 10, 23, 15, tzinfo=UTC), early=timedelta(minutes=30), hours=18)
    gfs = RunSource("gfs", datetime(2026, 10, 23, 12, tzinfo=UTC))
    departure = datetime(2026, 10, 23, 11, 30, tzinfo=UTC)
    result = forecast.compute(airports.lookup("JFK"), airports.lookup("LAX"), departure, now, [gtg, gfs], global_coverage=wide)
    assert gfs.read  # flown minutes did read the outlook
    assert result.source == "gtg" and result.model_run == gtg.cycle
    if wide:
        assert {s["source"] for s in result.sources} == {"gtg"}
    # A GTG run that ends before landing leaves the rest to the outlook: partly confirmed.
    short = RunSource("gtg", datetime(2026, 10, 23, 15, tzinfo=UTC), early=timedelta(minutes=30), hours=1.25)
    result = forecast.compute(airports.lookup("JFK"), airports.lookup("LAX"), departure, now, [short, gfs], global_coverage=wide)
    assert result.source == "mixed" and result.model_run == short.cycle


def test_minutes_still_ahead_that_nothing_covers_are_an_error():
    now = datetime(2026, 10, 23, 17, tzinfo=UTC)
    short = RunSource("gtg", datetime(2026, 10, 23, 15, tzinfo=UTC), hours=4)
    with pytest.raises(RuntimeError):
        forecast.compute(airports.lookup("JFK"), airports.lookup("LAX"), now, now, [short])
