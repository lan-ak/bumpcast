"""Gusty takeoffs and landings: which airport forecasts count, when an end is gusty, and which
stretches get the cause. Tagging never changes a forecast's numbers or what a push says."""

from datetime import UTC, datetime, timedelta

import pytest

import smooth_worker
from smooth_worker import airfield, airports, changes, forecast

NOW = datetime(2026, 10, 28, 12, tzinfo=UTC)


def ts(hours: float) -> int:
    return int((NOW + timedelta(hours=hours)).timestamp())


def taf(*groups, valid=(-1, 29), issued=-0.5, icao="CYYZ") -> dict:
    """A TAF in the aviationweather.gov JSON shape. Groups: (from h, to h, change, probability, gust)."""
    return {
        "icaoId": icao,
        "issueTime": (NOW + timedelta(hours=issued)).isoformat().replace("+00:00", "Z"),
        "validTimeFrom": ts(valid[0]),
        "validTimeTo": ts(valid[1]),
        "fcsts": [
            {"timeFrom": ts(a), "timeTo": ts(b), "fcstChange": change, "probability": prob, "wgst": gust}
            for a, b, change, prob, gust in groups
        ],
    }


def window(hours: float) -> tuple[datetime, datetime]:
    at = NOW + timedelta(hours=hours)
    return at - airfield.WINDOW, at + airfield.WINDOW


def test_maybes_never_count():
    t = airfield.parse(taf(
        (-1, 29, None, None, None),
        (2, 6, "TEMPO", 30, 40),  # PROB30 TEMPO: a maybe
        (2, 6, "PROB", 40, 45),
        (2, 6, "TEMPO", None, 28),
    ))
    assert t.gust_kt(*window(4)) == 28


def test_a_becoming_change_lasts_until_the_next_group():
    t = airfield.parse(taf(
        (-1, 3, None, None, None),
        (3, 4, "BECMG", None, 30),
        (10, 29, "FM", None, None),
    ))
    assert t.gust_kt(*window(7)) == 30
    assert t.gust_kt(*window(12)) == 0


def test_a_window_the_forecast_doesnt_reach_is_unknown():
    t = airfield.parse(taf((-1, 8, None, None, 30), valid=(-1, 8)))
    assert t.gust_kt(*window(4)) == 30
    assert t.gust_kt(*window(7.5)) is None


@pytest.fixture
def forecasts(monkeypatch):
    """Serve these TAFs; `down` makes the feed fail."""
    served: dict = {"tafs": {}, "down": False}

    def fetch(icaos):
        if served["down"]:
            raise airfield.httpx.ConnectError("down")
        return {i: airfield.parse(served["tafs"][i]) for i in icaos if i in served["tafs"]}

    monkeypatch.setattr(airfield, "_fetch", fetch)
    return served


TORONTO = airports.lookup("CYYZ")


def test_gusts_of_25_knots_make_an_end_gusty(forecasts):
    forecasts["tafs"]["CYYZ"] = taf((-1, 29, None, None, 25))
    assert airfield.decide("origin", TORONTO, window(3), None, NOW).gusty
    airfield.reset()
    forecasts["tafs"]["CYYZ"] = taf((-1, 29, None, None, 24))
    assert not airfield.decide("origin", TORONTO, window(3), None, NOW).gusty


def test_once_gusty_it_settles_below_20(forecasts):
    forecasts["tafs"]["CYYZ"] = taf((-1, 29, None, None, 22))
    held = airfield.decide("origin", TORONTO, window(3), {"gusty": True}, NOW)
    assert held.gusty and held.held
    airfield.reset()
    forecasts["tafs"]["CYYZ"] = taf((-1, 29, None, None, 18))
    assert not airfield.decide("origin", TORONTO, window(3), {"gusty": True}, NOW).gusty


def test_a_failed_feed_keeps_a_gusty_answer_only_while_its_forecast_covers(forecasts):
    forecasts["down"] = True
    covering = {"gusty": True, "gust_kt": 30, "taf_valid_to": (NOW + timedelta(hours=10)).isoformat()}
    carried = airfield.decide("origin", TORONTO, window(3), covering, NOW)
    assert carried.gusty and carried.carried and carried.status == "feed_down"
    expired = {**covering, "taf_valid_to": (NOW + timedelta(hours=2)).isoformat()}
    assert not airfield.decide("origin", TORONTO, window(3), expired, NOW).gusty
    assert not airfield.decide("origin", TORONTO, window(3), None, NOW).gusty


def test_no_forecast_clears_it(forecasts):
    gone = airfield.decide("origin", TORONTO, window(3), {"gusty": True}, NOW)
    assert not gone.gusty and gone.status == "no_forecast"


def ready(segments, source="gtg", samples=None, sources=None) -> forecast.Forecast:
    # Climb from 600 ft, cruise, and come down to 600 ft at minute 59.
    samples = samples or [
        {"min": m, "edr": 0.05, "altitude_ft": min(600 + 1000 * m, 37000, 600 + 1000 * (59 - m))} for m in range(60)
    ]
    return forecast.Forecast(
        status="ready", source=source, grade="mostly_smooth", score=95, duration_min=59,
        segments=segments, samples=samples, sources=sources or [],
    )


def seg(start, end, phase, altitude, severity="light"):
    return {"start_min": start, "end_min": end, "severity": severity, "peak_edr": 0.12, "phase": phase,
            "altitude_ft": altitude}


ENDS = {"origin": TORONTO, "destination": airports.lookup("KEWR")}


def test_only_stretches_peaking_near_the_ground_are_tagged():
    near, high, cruise = seg(0, 3, "climb", 600), seg(5, 10, "climb", 8200), seg(20, 25, "cruise", 37000)
    result = ready([near, high, cruise])
    gusty = airfield.End("origin", "CYYZ", window(0), gusty=True)
    [shadow] = airfield.tag(result, [gusty], ENDS, forecast._grade)
    assert near["cause"] == "wind_origin"
    assert "cause" not in high and "cause" not in cruise
    assert shadow["tagged"] == [0]
    assert shadow["excluded"] == [{"start_min": 5, "reason": "above_layer", "altitude_ft": 8200}]


def test_outlook_stretches_are_never_tagged():
    climb = seg(0, 3, "climb", 600)
    mixed = ready([climb], source="mixed", sources=[{"start_min": 0, "end_min": 1, "source": "gtg"},
                                                    {"start_min": 2, "end_min": 59, "source": "gfs"}])
    [shadow] = airfield.tag(mixed, [airfield.End("origin", "CYYZ", window(0), gusty=True)], ENDS, forecast._grade)
    assert "cause" not in climb and shadow["excluded"][0]["reason"] == "outlook"


def test_a_calm_end_tags_nothing_and_the_floor_is_shadow_only():
    climb = seg(0, 3, "climb", 600)
    result = ready([climb])
    calm, gusty = airfield.End("origin", "CYYZ", window(0)), airfield.End("destination", "KEWR", window(1), gusty=True)
    shadow = airfield.tag(result, [calm, gusty], ENDS, forecast._grade)
    assert "cause" not in climb and "floor_min" not in shadow[0]
    # The landing end is gusty with no stretch there: what a floor would add is recorded, not applied.
    assert shadow[1]["tagged"] == [] and shadow[1]["floor_min"] >= 1
    assert result.grade == "mostly_smooth" and all(s["edr"] == 0.05 for s in result.samples)


def test_a_cause_alone_never_changes_what_an_update_says():
    old = {"status": "ready", "source": "gtg", "grade": "some_bumps", "segments": [seg(0, 3, "climb", 600)]}
    tagged = {**old, "segments": [{**seg(0, 3, "climb", 600), "cause": "wind_origin"}]}
    assert changes.describe(old, tagged) == changes.describe(old, old)


def test_the_forecast_pass_times_the_ends_like_the_pushes(forecasts):
    forecasts["tafs"]["CYYZ"] = taf((-1, 29, None, None, 32), icao="CYYZ")
    flight = {"id": "f1", "origin": "CYYZ", "destination": "KEWR", "status": None}
    climb = seg(0, 3, "climb", 600)
    result = ready([climb])
    smooth_worker.airport_wind(flight, NOW + timedelta(hours=2), result, None, NOW)
    origin, destination = result.airport_wind
    assert climb["cause"] == "wind_origin" and origin["gust_kt"] == 32
    # Takeoff 15 min after the gate, landing a 59-minute flight later.
    assert origin["window_from"] == (NOW + timedelta(hours=2, minutes=15) - airfield.WINDOW).isoformat()
    assert destination["status"] == "no_forecast" and not destination["gusty"]
    assert "airport_wind" in result.to_row()


def test_the_outlook_never_fetches_airport_forecasts(forecasts):
    forecasts["down"] = True  # would be noticed
    result = ready([seg(0, 3, "climb", 600)], source="gfs")
    smooth_worker.airport_wind({"id": "f1", "origin": "CYYZ", "destination": "KEWR"}, NOW, result, None, NOW)
    assert result.airport_wind == []
