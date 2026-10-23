"""The flight profile: fitted to real ADS-B tracks (see route.py), with and without winds."""

from datetime import UTC, datetime, timedelta

import numpy as np
import pytest

from smooth_worker import airports, forecast, route
from smooth_worker.route import TAXI_OUT_MIN, build_profile, distance_nm

NOW = datetime(2026, 10, 22, 18, 35, tzinfo=UTC)


def top_of_climb(points):
    return next(p.minute for p in points if p.phase == "cruise")


def top_of_descent(points):
    return max(p.minute for p in points if p.phase == "cruise")


def assert_sane(points, origin, destination):
    """Consecutive minutes, climb up / cruise level or stepping up / descent down, from one
    airport to the other, never below either field."""
    assert [p.minute for p in points] == list(range(len(points)))
    assert all(b.time - a.time == timedelta(minutes=1) for a, b in zip(points, points[1:]))
    order = {"climb": 0, "cruise": 1, "descent": 2}
    assert all(order[a.phase] <= order[b.phase] for a, b in zip(points, points[1:]))
    alts = [p.altitude_ft for p in points]
    first, last = alts.index(max(alts)), len(alts) - 1 - alts[::-1].index(max(alts))
    assert all(a <= b for a, b in zip(alts[:first], alts[1 : first + 1]))  # climb, and step climbs
    assert all(a >= b for a, b in zip(alts[last:], alts[last + 1 :]))  # descent
    low = min(origin.elev_ft, destination.elev_ft) - 50
    assert min(alts) >= low
    assert alts[0] == round(origin.elev_ft, -2) and alts[-1] == round(destination.elev_ft, -2)
    assert (points[0].lat, points[0].lon) == pytest.approx((origin.lat, origin.lon), abs=1e-6)
    assert (points[-1].lat, points[-1].lon) == pytest.approx((destination.lat, destination.lon), abs=1e-6)
    along = [distance_nm(origin, airports.Airport("", "", "", "", "", p.lat, p.lon, 0, "")) for p in points]
    assert all(a <= b + 1e-6 for a, b in zip(along, along[1:]))  # never flies backwards


def test_ac1507_ewr_yyz_matches_the_reference_flight():
    """AC 1507 EWR-YYZ on 2026-10-22 (A220-300): FL280, level at FL280 19.7 min after wheels-up,
    down 61.4-61.9 min after. The old profile had FL310, top of climb at 16 and landing at 52."""
    ewr, yyz = airports.lookup("EWR"), airports.lookup("YYZ")
    points = build_profile(ewr, yyz, NOW)
    assert points[0].time == NOW + timedelta(minutes=TAXI_OUT_MIN)
    assert abs(max(p.altitude_ft for p in points) - 28000) <= 1000
    assert 17 <= top_of_climb(points) <= 22
    assert 57 <= points[-1].minute <= 65
    # The descent starts about 25 min before landing (real: 25.8), not 21 as before.
    assert 20 <= points[-1].minute - top_of_descent(points) <= 30
    assert_sane(points, ewr, yyz)


def test_taxi_out_stays_in_step_with_status_and_the_app():
    from smooth_worker import status

    assert route.TAXI_OUT_MIN == status.TAXI_OUT_MIN == 15  # the app's Forecast.taxiOut


@pytest.mark.parametrize(
    ("origin", "destination", "level"),
    [
        ("LGA", "BOS", 21000),  # 160 nm eastbound: DAL1651 flew FL210
        ("EWR", "YYZ", 28000),  # westbound, even
        ("ORD", "YYZ", 31000),  # 378 nm eastbound: ACA506 flew FL330, then FL310
        ("LAX", "SEA", 36000),  # ASA798 flew FL360
        ("DFW", "ATL", 35000),  # AAL1008 flew FL350
        ("JFK", "DEN", 34000),  # long, so heavier and lower first: JBU1497 flew FL300
        ("LAX", "JFK", 35000),  # then step climbs: AAL2 went FL310 to FL370
    ],
)
def test_cruise_level_by_distance_and_direction(origin, destination, level):
    points = build_profile(airports.lookup(origin), airports.lookup(destination), NOW)
    assert points[top_of_climb(points)].altitude_ft == level


def test_flown_distance_adds_terminal_miles():
    assert route.flown_nm(0) == 0
    assert route.flown_nm(10) == pytest.approx(20.25)  # a tiny hop never more than doubles
    assert route.flown_nm(301.8) == pytest.approx(334.3, abs=0.1)  # AC 1507 flew 352
    assert route.flown_nm(2991) == pytest.approx(3090.8, abs=0.1)  # BAW112 flew 3,037, VIR3 3,076


def shape(points):
    return [(p.minute, p.altitude_ft, p.phase, round(p.lat, 4), round(p.lon, 4)) for p in points]


def uniform(u_kt: float, v_kt: float = 0.0):
    return lambda lat, lon, altitude_ft, time: (u_kt, v_kt)


def test_winds_make_eastbound_faster_than_westbound():
    jfk, lax = airports.lookup("JFK"), airports.lookup("LAX")
    still_west = build_profile(jfk, lax, NOW)[-1].minute
    still_east = build_profile(lax, jfk, NOW)[-1].minute
    jet = uniform(100)  # a 100 kt westerly at every height
    west = build_profile(jfk, lax, NOW, wind=jet)
    east = build_profile(lax, jfk, NOW, wind=jet)
    assert east[-1].minute < still_east and west[-1].minute > still_west
    assert west[-1].minute - east[-1].minute > 90
    assert 200 < east[-1].minute < 300 < 330 < west[-1].minute < 450
    # Calm winds change nothing.
    assert shape(build_profile(jfk, lax, NOW, wind=uniform(0))) == shape(build_profile(jfk, lax, NOW))
    assert_sane(west, jfk, lax)
    assert_sane(east, lax, jfk)


def test_crosswind_slows_a_little_and_bad_winds_are_ignored():
    ord_, den = airports.lookup("ORD"), airports.lookup("DEN")
    still = build_profile(ord_, den, NOW)[-1].minute
    across = build_profile(ord_, den, NOW, wind=uniform(0, 80))[-1].minute  # southerly across a westbound track
    assert still <= across <= still + 10
    for bad in (uniform(float("nan")), uniform(900), lambda *a: None):
        assert shape(build_profile(ord_, den, NOW, wind=bad)) == shape(build_profile(ord_, den, NOW))


def test_winds_are_read_where_and_when_the_flight_is():
    seen = []

    def wind(lat, lon, altitude_ft, time):
        seen.append((lat, lon, altitude_ft, time))
        return (0.0, 0.0)

    lax, jfk = airports.lookup("LAX"), airports.lookup("JFK")
    points = build_profile(lax, jfk, NOW, wind=wind)
    takeoff, landing = points[0].time, points[-1].time
    assert all(takeoff - timedelta(minutes=8) <= t <= landing + timedelta(minutes=8) for *_, t in seen)
    assert min(lon for _, lon, *_ in seen) < -115 and max(lon for _, lon, *_ in seen) > -75
    assert max(alt for _, _, alt, _ in seen) == max(p.altitude_ft for p in points)


@pytest.mark.parametrize(
    ("origin", "destination"),
    [
        ("SFO", "OAK"),  # 10 nm
        ("LGA", "JFK"),
        ("SFO", "SJC"),  # 26 nm
        ("DEN", "PHX"),  # leaves at 5,431 ft
        ("PHX", "DEN"),
        ("ASE", "DEN"),  # both high, 109 nm
        ("LPB", "CUZ"),  # La Paz, 13,355 ft
        ("JFK", "SIN"),  # 8,283 nm
        ("SYD", "DFW"),
        ("JNB", "LHR"),
    ],
)
def test_odd_routes_stay_sane(origin, destination):
    o, d = airports.lookup(origin), airports.lookup(destination)
    for wind in (None, uniform(60, -20)):
        points = build_profile(o, d, NOW, wind=wind)
        assert_sane(points, o, d)
        assert max(p.altitude_ft for p in points) <= route.STEP_MAX_FT
        hours = points[-1].minute / 60
        speed = route.flown_nm(distance_nm(o, d)) / hours
        assert 40 < speed < 620, (origin, destination, speed)


def test_very_long_flights_step_up_and_take_their_time():
    jfk, sin = airports.lookup("JFK"), airports.lookup("SIN")
    points = build_profile(jfk, sin, NOW)
    levels = sorted({p.altitude_ft for p in points if p.phase == "cruise"})
    assert levels[0] == 35000 and levels[-1] == 39000  # FL350 eastbound, stepping to FL390
    assert 16 * 60 < points[-1].minute < 20 * 60  # SQ 23 is about 18 h in the air


def test_same_airport_is_a_single_point():
    jfk = airports.lookup("JFK")
    [point] = build_profile(jfk, jfk, NOW)
    assert (point.minute, point.altitude_ft, point.time) == (0, 0, NOW + timedelta(minutes=15))


def test_short_hops_cap_the_level():
    sfo, sjc = airports.lookup("SFO"), airports.lookup("SJC")
    points = build_profile(sfo, sjc, NOW)
    assert 3000 <= max(p.altitude_ft for p in points) <= 12000
    assert 8 <= points[-1].minute <= 20


# GFS winds


def gfs_with_winds(tmp_path, u_kt, v_kt, cycle=NOW):
    from smooth_worker.sources.gfs import GfsSource, tile_of

    source = GfsSource(cycle, tmp_path)
    lats = np.array([43.0, 42.0, 41.0])
    lons = np.array([285.0, 286.0, 287.0])
    heights = np.broadcast_to(np.array([5000.0, 30000.0, 40000.0])[:, None, None], (3, 3, 3)).astype(np.float32)
    u = np.broadcast_to(np.array([10.0, u_kt, u_kt])[:, None, None], (3, 3, 3)).astype(np.float32)
    v = np.full((3, 3, 3), v_kt, dtype=np.float32)
    for fhr in range(0, 8):
        key = (fhr, tile_of(42.0, -74.0))
        source._tiles[key] = (lats, lons, heights, np.zeros((3, 3, 3)))
        source._winds[key] = (lats, lons, heights, u, v)
    return source


def test_gfs_wind_by_height_and_time(tmp_path):
    source = gfs_with_winds(tmp_path, 80.0, -5.0)
    assert source.wind(42.1, -74.0, 30000, NOW + timedelta(hours=2)) == pytest.approx((80.0, -5.0))
    assert source.wind(42.1, -74.0, 17500, NOW + timedelta(hours=2)) == pytest.approx((45.0, -5.0))
    assert source.wind(42.1, -74.0, 1000, NOW)[0] == pytest.approx(10.0)  # below the lowest level
    # Minutes flown before the run began read its start; beyond its reach, nothing.
    assert source.wind(42.1, -74.0, 30000, NOW - timedelta(hours=1)) == pytest.approx((80.0, -5.0))
    assert source.wind(42.1, -74.0, 30000, NOW + timedelta(hours=121)) is None


class WindySource:
    """Smooth air everywhere, with a westerly jet, like GFS."""

    name, cycle = "gfs", NOW

    def __init__(self, u_kt=120.0, fail=False):
        self.u_kt, self.fail = u_kt, fail

    def covers(self, valid):
        return True

    def edr(self, lat, lon, altitude_ft, valid):
        return 0.03

    def wind(self, lat, lon, altitude_ft, valid):
        if self.fail:
            raise RuntimeError("NOMADS said no")
        return (self.u_kt, 0.0)


def test_forecast_uses_the_sources_winds():
    jfk, lax = airports.lookup("JFK"), airports.lookup("LAX")
    still = forecast.compute(jfk, lax, NOW, NOW, [WindySource(u_kt=0)])
    headwind = forecast.compute(jfk, lax, NOW, NOW, [WindySource()])
    tailwind = forecast.compute(lax, jfk, NOW, NOW, [WindySource()])
    assert tailwind.duration_min < still.duration_min < headwind.duration_min
    assert len(headwind.samples) == headwind.duration_min + 1


def test_forecast_without_winds_when_they_fail():
    jfk, lax = airports.lookup("JFK"), airports.lookup("LAX")
    failing = forecast.compute(jfk, lax, NOW, NOW, [WindySource(fail=True)])
    assert failing.status == "ready"
    assert failing.duration_min == build_profile(jfk, lax, NOW)[-1].minute


def test_routes_outside_coverage_never_read_winds():
    calls = []

    class CountingSource(WindySource):
        def wind(self, *args, **kwargs):
            calls.append(args)
            return super().wind(*args, **kwargs)

    yyz, lhr = airports.lookup("YYZ"), airports.lookup("LHR")
    result = forecast.compute(yyz, lhr, NOW, NOW, [CountingSource()], global_coverage=False)
    assert result.status == "out_of_coverage"
    assert calls == []


def test_ready_forecasts_record_the_profile_version():
    from smooth_worker.route import PROFILE_VERSION

    jfk, lax = airports.lookup("JFK"), airports.lookup("LAX")
    result = forecast.compute(jfk, lax, NOW, NOW, [WindySource(u_kt=0)])
    assert result.to_row()["profile"] == PROFILE_VERSION
