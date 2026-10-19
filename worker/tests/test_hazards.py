from datetime import UTC, datetime, timedelta

from smooth_worker import airports, changes, forecast, hazards, notify
from smooth_worker.severity import SEVERE, classify

NOW = datetime(2026, 10, 18, 12, tzinfo=UTC)
EPOCH = int(NOW.timestamp())


def isigmet(**over):
    row = {
        "firName": "LPPO SANTA MARIA OCEANIC",
        "hazard": "TURB",
        "qualifier": "SEV",
        "validTimeFrom": EPOCH - 3600,
        "validTimeTo": EPOCH + 6 * 3600,
        "base": 30000,
        "top": 40000,
        "coords": [{"lat": 40, "lon": -30}, {"lat": 40, "lon": -20}, {"lat": 30, "lon": -20}, {"lat": 30, "lon": -30}],
    }
    return row | over


def test_sigmet_polygon_altitude_and_time():
    [h] = hazards.from_isigmets([isigmet()])
    assert h.severity == SEVERE and h.region == "Santa Maria Oceanic"
    assert h.applies(35, -25, 35000, NOW)
    assert not h.applies(35, -25, 20000, NOW)  # below the warned band
    assert not h.applies(45, -25, 35000, NOW)  # outside the area
    assert not h.applies(35, -25, 35000, NOW + timedelta(hours=8))  # expired
    assert "Official warning" in h.label


def test_sigmet_across_the_dateline():
    coords = [{"lat": 10, "lon": 175}, {"lat": 10, "lon": -175}, {"lat": 0, "lon": -175}, {"lat": 0, "lon": 175}]
    [h] = hazards.from_isigmets([isigmet(coords=coords)])
    assert h.applies(5, 179.5, 35000, NOW) and h.applies(5, -179.5, 35000, NOW)
    assert not h.applies(5, 170, 35000, NOW)


def test_sigmet_on_the_far_side_of_the_world():
    # New York Oceanic seen from Tokyo -> Singapore: the shifted polygon used to straddle the point.
    coords = [{"lat": 30, "lon": -70}, {"lat": 30, "lon": -40}, {"lat": 20, "lon": -40}, {"lat": 20, "lon": -70}]
    [h] = hazards.from_isigmets([isigmet(coords=coords, base=0)])
    assert h.applies(25, -55, 35000, NOW)
    for lon in (140.0, 125.0, 110.0, 179.0, -179.0):
        assert not h.applies(25, lon, 35000, NOW)


def test_irrelevant_sigmets_ignored_and_mountain_waves_named():
    assert hazards.from_isigmets([isigmet(hazard="ICE"), isigmet(hazard="VA"), isigmet(coords=[])]) == []
    [mtw] = hazards.from_isigmets([isigmet(qualifier="SEV MTW")])
    assert mtw.hazard == "mountain_wave"
    [ts] = hazards.from_isigmets([isigmet(hazard="TS", qualifier="EMBD")])
    assert ts.hazard == "thunderstorms" and ts.severity == "moderate"


def test_multi_area_sigmet_and_malformed_rows():
    a = [{"lat": 0, "lon": 9}, {"lat": 3, "lon": 14}, {"lat": 3, "lon": 16}, {"lat": 0, "lon": 11}]
    b = [{"lat": 0, "lon": 9}, {"lat": -4, "lon": 13}, {"lat": -4, "lon": 15}, {"lat": 0, "lon": 11}]
    rows = [isigmet(hazard="TS", coords=[a, b]), isigmet(validTimeFrom="soon"), isigmet(coords=[{"lat": 1}] * 3)]
    found = hazards.from_isigmets(rows)
    assert len(found) == 2 and all(h.hazard == "thunderstorms" for h in found)


def test_pirep_radius_and_window():
    rows = [{"lat": 40.0, "lon": -100.0, "obsTime": EPOCH, "fltLvl": 350, "tbInt1": "MOD"}, "junk", {"lat": 1}]
    [h] = hazards.from_pireps(rows)
    assert h.applies(40.3, -100.3, 34000, NOW + timedelta(hours=1))
    assert not h.applies(42.0, -100.0, 35000, NOW)  # ~120 nm away
    assert not h.applies(40.0, -100.0, 25000, NOW)  # 10,000 ft below
    assert not h.applies(40.0, -100.0, 35000, NOW + timedelta(hours=3))  # too old by then


class Calm:
    name, cycle = "gfs", NOW

    def covers(self, valid):
        return True

    def edr(self, *args):
        return 0.03


def test_warning_raises_outlook_to_severe_and_is_listed():
    # LHR -> JFK passes about 52N 30W; put a severe warning there at cruise.
    coords = [{"lat": 56, "lon": -35}, {"lat": 56, "lon": -25}, {"lat": 48, "lon": -25}, {"lat": 48, "lon": -35}]
    warn = hazards.from_isigmets([isigmet(coords=coords, firName="EGGX SHANWICK OCEANIC")])
    result = forecast.compute(
        airports.lookup("LHR"), airports.lookup("JFK"), NOW, NOW, [Calm()], warn, global_coverage=True
    )
    assert result.grade in ("bumpy", "rough")
    assert any(s["severity"] == SEVERE for s in result.segments)
    [w] = result.warnings
    assert w["kind"] == "sigmet" and w["severity"] == SEVERE and "Shanwick Oceanic" in w["label"]
    assert all(classify(s["edr"]) == SEVERE for s in result.samples if w["start_min"] <= s["min"] <= w["end_min"])


def test_outlook_only_route_never_says_confirmed():
    assert changes.confidence("mixed", noaa_possible=False) == "early"
    assert changes.confidence("mixed") == "partly confirmed"
    sent = [{"milestone": "48h", "source": "gfs"}]
    international = {"status": "ready", "source": "mixed", "noaa_possible": False}
    assert notify.plan(30, international, sent) is None
    assert notify.plan(30, {**international, "noaa_possible": True}, sent).kind == "confirmed"
