from datetime import UTC, datetime, timedelta

import pytest

from smooth_worker import airports, forecast, skyreport
from smooth_worker.route import build_profile

# 10 am in New York: today's 8 am departures from the east have gone.
NOW = datetime(2026, 10, 26, 14, tzinfo=UTC)


class Constant:
    name = "gfs"
    cycle = NOW

    def __init__(self, edr=0.03):
        self.value = edr

    def covers(self, valid):
        return True

    def edr(self, lat, lon, altitude_ft, valid):
        return self.value


def compute_with(source):
    def compute(origin, destination, departure):
        return forecast.compute(origin, destination, departure, NOW, [source], global_coverage=False)

    return compute


@pytest.mark.parametrize(("origin", "destination"), skyreport.ROUTES)
def test_every_route_is_in_coverage(origin, destination):
    o, d = airports.lookup(origin), airports.lookup(destination)
    assert forecast.in_coverage(build_profile(o, d, NOW))


def test_routes_are_unique():
    assert len(set(skyreport.ROUTES)) == len(skyreport.ROUTES)


def test_departures_today_and_tomorrow_in_local_time():
    report = skyreport.route_report(airports.lookup("JFK"), airports.lookup("LAX"), NOW, compute_with(Constant()))
    assert report["slug"] == "jfk-lax"
    assert [d["date"] for d in report["days"]] == ["2026-10-26", "2026-10-27"]
    today, tomorrow = report["days"]
    assert [d["slot"] for d in today["departures"]] == ["afternoon", "evening"]  # 8 am has gone
    assert [d["slot"] for d in tomorrow["departures"]] == ["morning", "afternoon", "evening"]
    # 8 am EDT
    assert tomorrow["departures"][0]["departure_at"] == "2026-10-27T12:00:00+00:00"
    assert 300 < report["duration_min"] < 420


def test_west_coast_uses_its_own_clock():
    # 7 am in Los Angeles: 8 am is still listed.
    report = skyreport.route_report(airports.lookup("LAX"), airports.lookup("JFK"), NOW, compute_with(Constant()))
    assert [d["slot"] for d in report["days"][0]["departures"]] == ["morning", "afternoon", "evening"]
    # 7:40 am: 8 am is too close to list (MIN_LEAD).
    later = skyreport.route_report(
        airports.lookup("LAX"), airports.lookup("JFK"), NOW + timedelta(minutes=40), compute_with(Constant())
    )
    assert [d["slot"] for d in later["days"][0]["departures"]] == ["afternoon", "evening"]


def test_grade_only_never_the_timeline():
    report = skyreport.route_report(airports.lookup("ORD"), airports.lookup("LGA"), NOW, compute_with(Constant(0.25)))
    entry = report["days"][-1]["departures"][0]
    assert entry["grade"] == "bumpy" and entry["grade_title"] == "Bumpy in places"
    assert entry["confidence"] == "early" and entry["confidence_title"] == "Early outlook"
    assert set(entry) == {
        "slot", "departure_at", "status", "grade", "grade_title", "score", "confidence", "confidence_title"
    }


def test_build_leaves_out_failed_routes():
    def compute(origin, destination, departure):
        if origin.iata == "BOS":
            raise RuntimeError("no data")
        return compute_with(Constant())(origin, destination, departure)

    report = skyreport.build(NOW, compute, [("BOS", "LAX"), ("JFK", "MIA")])
    assert [r["slug"] for r in report["routes"]] == ["jfk-mia"]
    assert report["failed"] == ["bos-lax"]
    assert report["generated_at"] == NOW.isoformat()


def test_is_due():
    assert skyreport.is_due(None, NOW)
    assert not skyreport.is_due((NOW - timedelta(minutes=30)).isoformat(), NOW)
    assert skyreport.is_due((NOW - timedelta(hours=1)).isoformat().replace("+00:00", "Z"), NOW)
